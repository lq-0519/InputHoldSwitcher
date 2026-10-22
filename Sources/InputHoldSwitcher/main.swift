import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

private enum DefaultsKey {
    static let releaseInputSourceID = "releaseInputSourceID"
    static let triggerKeyCode = "triggerKeyCode"
    static let triggerIsModifier = "triggerIsModifier"
    static let triggerDisplayName = "triggerDisplayName"
    static let enabled = "enabled"
    /// Stores the delay in seconds before switching to the release input source.
    static let releaseSwitchDelaySeconds = "releaseSwitchDelaySeconds"
}

/// Default delay used before switching back after the trigger key is released.
private let defaultReleaseSwitchDelaySeconds: TimeInterval = 0.10
/// Smallest allowed release delay in seconds.
private let minimumReleaseSwitchDelaySeconds: TimeInterval = 0
/// Largest allowed release delay in seconds.
private let maximumReleaseSwitchDelaySeconds: TimeInterval = 10
/// Input source identifier used to recognize when Doubao has become active.
private let doubaoInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
/// Bundle identifier used to recognize Doubao-owned voice windows.
private let doubaoBundleIdentifier = "com.bytedance.inputmethod.doubaoime"
/// Wait before checking whether Doubao's voice window appeared normally.
private let voiceFallbackCheckDelaySeconds: TimeInterval = 0.80
/// Interval for checking when an active voice window closes after a switch-back deadline expires.
/// Checks run only while a release task is waiting for voice input to finish.
private let releaseVoiceRecheckIntervalSeconds: TimeInterval = 0.10
/// Low-frequency interval used only to verify that the long-lived event tap remains enabled.
private let eventTapWatchdogIntervalSeconds: TimeInterval = 30

/// Clamps a release delay so user input cannot create an unusable schedule.
private func clampedReleaseSwitchDelay(_ value: TimeInterval) -> TimeInterval {
    min(max(value, minimumReleaseSwitchDelaySeconds), maximumReleaseSwitchDelaySeconds)
}

/// Returns the configured release delay, falling back to the app default.
private func configuredReleaseSwitchDelaySeconds() -> TimeInterval {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: DefaultsKey.releaseSwitchDelaySeconds) != nil else {
        return defaultReleaseSwitchDelaySeconds
    }
    return clampedReleaseSwitchDelay(defaults.double(forKey: DefaultsKey.releaseSwitchDelaySeconds))
}

/// Formats a delay value for display in the settings window.
private func formatDelaySeconds(_ value: TimeInterval) -> String {
    String(format: "%.2f", value)
}

private final class LoginItemManager {
    static let shared = LoginItemManager()

    private init() {}

    /// Returns whether this app is currently enabled as a macOS login item.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns a short user-facing description for the current login item status.
    func statusDescription() -> String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "已开启"
        case .notRegistered:
            return "未开启"
        case .requiresApproval:
            return "需要在系统设置中批准"
        case .notFound:
            return "找不到当前应用"
        @unknown default:
            return "未知状态"
        }
    }

    /// Registers or unregisters this app as a macOS login item.
    func setEnabled(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            AppLog.shared.write("login item set enabled=\(enabled) status=\(statusDescription())")
            return nil
        } catch {
            AppLog.shared.write("login item set failed enabled=\(enabled) error=\(error.localizedDescription)")
            return "设置开机自动启动失败：\(error.localizedDescription)"
        }
    }
}

private final class AppLog {
    static let shared = AppLog()

    let fileURL: URL
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        fileURL = logsDirectory.appendingPathComponent("InputHoldSwitcher.log")
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [pid:\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 日志失败不能影响输入法切换主流程。
        }
    }
}

private struct TriggerKey: Equatable {
    let keyCode: UInt16
    let isModifier: Bool
    let displayName: String

    static let defaultKey = TriggerKey(keyCode: 59, isModifier: true, displayName: "左 Control")

    static func load() -> TriggerKey {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DefaultsKey.triggerKeyCode) != nil else {
            return .defaultKey
        }
        return TriggerKey(
            keyCode: UInt16(defaults.integer(forKey: DefaultsKey.triggerKeyCode)),
            isModifier: defaults.bool(forKey: DefaultsKey.triggerIsModifier),
            displayName: defaults.string(forKey: DefaultsKey.triggerDisplayName) ?? "按键 \(defaults.integer(forKey: DefaultsKey.triggerKeyCode))"
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: DefaultsKey.triggerKeyCode)
        defaults.set(isModifier, forKey: DefaultsKey.triggerIsModifier)
        defaults.set(displayName, forKey: DefaultsKey.triggerDisplayName)
    }
}

private struct InputSourceInfo: Equatable {
    let id: String
    let name: String
    let source: TISInputSource
}

private final class InputSourceManager {
    static let shared = InputSourceManager()

    private(set) var sources: [InputSourceInfo] = []

    @discardableResult
    func refresh() -> [InputSourceInfo] {
        let query = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceIsEnabled: kCFBooleanTrue as Any
        ] as CFDictionary

        let rawSources = TISCreateInputSourceList(query, false).takeRetainedValue() as NSArray
        var result: [InputSourceInfo] = []
        for case let source as TISInputSource in rawSources {
            guard
                let id = stringProperty(source, kTISPropertyInputSourceID),
                let name = stringProperty(source, kTISPropertyLocalizedName)
            else { continue }

            if boolProperty(source, kTISPropertyInputSourceIsSelectCapable) == false {
                continue
            }
            result.append(InputSourceInfo(id: id, name: name, source: source))
        }

        sources = result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return sources
    }

    func switchTo(id: String, completion: ((String?) -> Void)? = nil) {
        if sources.isEmpty { refresh() }
        AppLog.shared.write("switch request target=\(id) current=\(currentSourceID() ?? "<unknown>")")
        guard let target = sources.first(where: { $0.id == id }) else {
            AppLog.shared.write("switch failed target=\(id) reason=source-not-found")
            completion?("找不到输入法：\(id)。请确认它已在系统设置中启用。")
            return
        }

        let status = TISSelectInputSource(target.source)
        if status == noErr {
            AppLog.shared.write("switch accepted target=\(id) current-immediate=\(currentSourceID() ?? "<unknown>")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                AppLog.shared.write("switch settled target=\(id) current=\(self.currentSourceID() ?? "<unknown>")")
            }
            completion?(nil)
        } else {
            AppLog.shared.write("switch failed target=\(id) status=\(status)")
            completion?("切换到“\(target.name)”失败，系统错误码：\(status)")
        }
    }

    func currentSourceID() -> String? {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return stringProperty(current, kTISPropertyInputSourceID)
    }

    private func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
}

private func accessibilityTrusted(prompt: Bool) -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    return HotKeyController.shared.handle(type: type, event: event)
}

private final class HotKeyController {
    static let shared = HotKeyController()

    var onStateChange: ((Bool, String) -> Void)?
    var onError: ((String) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Observes input-source transitions so a Doubao activation can restore tap precedence before release.
    private var inputSourceChangeObserver: NSObjectProtocol?
    /// Remembers the last selected input source so duplicate system notifications do not trigger maintenance repeatedly.
    private var lastObservedInputSourceID: String?
    /// Periodically checks the existing event tap and never replaces a healthy tap.
    private var eventTapWatchdogTimer: Timer?
    private var trigger = TriggerKey.load()
    private var triggerPressed = false
    private var ignoredModifierReleaseKeyCode: UInt16?
    /// Holds a queued event-tap replacement so concurrent recovery signals cannot schedule duplicate rebuilds.
    private var pendingEventTapRearm: DispatchWorkItem?
    /// Holds the pending switch-back task so a new press or settings change can cancel it.
    private var pendingReleaseSwitch: DispatchWorkItem?
    /// Identifies the current release cycle, including voice-window retries.
    /// Canceled callbacks must match this identity before changing tasks or switching input sources.
    private var pendingReleaseSwitchID: UUID?
    /// Holds the delayed voice-window check used only after switching from another input source.
    private var pendingVoiceFallback: DispatchWorkItem?
    /// Tracks whether this app sent a supplemental trigger down that still needs a matching up.
    private var supplementalTriggerDownSent = false

    /// Returns whether automatic switching after release is enabled.
    private var enabled: Bool {
        if UserDefaults.standard.object(forKey: DefaultsKey.enabled) == nil { return true }
        return UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
    }

    /// Starts a listen-only event tap that never blocks the real trigger key from reaching Doubao.
    func start() -> Bool {
        stop()
        trigger = TriggerKey.load()
        AppLog.shared.write("listener start trusted=\(accessibilityTrusted(prompt: false)) trigger=\(trigger.displayName) keyCode=\(trigger.keyCode) modifier=\(trigger.isModifier) mode=hid-release-only enabled=\(enabled)")
        guard accessibilityTrusted(prompt: false) else {
            AppLog.shared.write("listener start failed reason=accessibility-not-trusted")
            onStateChange?(false, "需要辅助功能权限")
            return false
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            AppLog.shared.write("listener start failed reason=event-tap-create-failed")
            onStateChange?(false, "无法监听键盘，请检查辅助功能权限")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startEventTapMaintenance()
        AppLog.shared.write("listener started eventTapEnabled=true")
        onStateChange?(true, enabled ? "运行中" : "已暂停")
        return true
    }

    /// Stops listening and cancels any switch-back that has not run yet.
    func stop() {
        if eventTap != nil { AppLog.shared.write("listener stopping") }
        stopEventTapMaintenance()
        cancelPendingEventTapRearm(reason: "listener-stopped")
        cancelPendingReleaseSwitch(reason: "listener-stopped")
        resetVoiceFallback(sendKeyUp: true, reason: "listener-stopped")
        invalidateEventTap(eventTap, source: runLoopSource)
        runLoopSource = nil
        eventTap = nil
        triggerPressed = false
    }

    /// Reloads the trigger and enabled state without replacing the active event tap.
    func reloadSettings(ignoreNextModifierReleaseFor keyCode: UInt16? = nil) {
        cancelPendingEventTapRearm(reason: "settings-reloaded")
        cancelPendingReleaseSwitch(reason: "settings-reloaded")
        resetVoiceFallback(sendKeyUp: true, reason: "settings-reloaded")
        trigger = TriggerKey.load()
        triggerPressed = false
        ignoredModifierReleaseKeyCode = keyCode
        if eventTap == nil, accessibilityTrusted(prompt: false) {
            _ = start()
        } else {
            onStateChange?(eventTap != nil, enabled ? "运行中" : "已暂停")
        }
    }

    /// Observes trigger transitions and always passes the original event through unchanged.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            AppLog.shared.write("event tap disabled type=\(type.rawValue); re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    scheduleEventTapRearm(reason: "callback-reenable-failed")
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard enabled else { return Unmanaged.passUnretained(event) }
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == trigger.keyCode else { return Unmanaged.passUnretained(event) }
        let eventPressed = event.flags.contains(modifierFlag(for: eventKeyCode))
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let sourceState = event.getIntegerValueField(.eventSourceStateID)
        AppLog.shared.write("trigger event type=\(eventTypeName(type)) keyCode=\(eventKeyCode) pressed-before=\(triggerPressed) event-pressed=\(eventPressed) flags=\(event.flags.rawValue) source-pid=\(sourcePID) source-state=\(sourceState)")

        if type == .flagsChanged, ignoredModifierReleaseKeyCode == eventKeyCode {
            ignoredModifierReleaseKeyCode = nil
            resetVoiceFallback(sendKeyUp: true, reason: "recording-release-ignored")
            triggerPressed = false
            return Unmanaged.passUnretained(event)
        }

        var matched = false
        if trigger.isModifier && type == .flagsChanged {
            matched = true
            if sourcePID != 0 {
                if eventPressed, !triggerPressed, isDoubaoProcess(sourcePID) {
                    // 豆包的回注按下只会出现在它先收到了真实快捷键之后。空闲状态下先看到它，说明本监听器的顺序已经落后。
                    triggerPressed = true
                    AppLog.shared.write("trigger physical press recovered from doubao injection source-pid=\(sourcePID)")
                    handleTriggerState(true)
                    scheduleEventTapRearm(reason: "doubao-injected-press-without-physical")
                } else {
                    // 回注的伪松开不能改变按住状态，否则会在用户真正松手前提前切回。
                    AppLog.shared.write("trigger injected modifier ignored source-pid=\(sourcePID) event-pressed=\(eventPressed)")
                }
            } else if eventPressed {
                if !triggerPressed {
                    triggerPressed = true
                    handleTriggerState(true)
                } else {
                    AppLog.shared.write("trigger modifier duplicate state=true; ignored state transition")
                }
            } else if triggerPressed {
                triggerPressed = false
                handleTriggerState(false)
            } else {
                // 即使之前的按下事件被输入法吞掉，真实硬件松开仍应保证自动切回。
                AppLog.shared.write("trigger physical release recovered while state=false")
                handleTriggerState(false)
            }
        } else if !trigger.isModifier && type == .keyDown {
            matched = true
            if !triggerPressed && !event.getIntegerValueField(.keyboardEventAutorepeat).boolValue {
                triggerPressed = true
                handleTriggerState(true)
            }
        } else if !trigger.isModifier && type == .keyUp {
            matched = true
            if triggerPressed {
                triggerPressed = false
                handleTriggerState(false)
            }
        }

        if matched {
            AppLog.shared.write("trigger handled pressed-after=\(triggerPressed) consumed=false")
        }
        return Unmanaged.passUnretained(event)
    }

    /// Returns whether an injected event originated from the currently running Doubao input method process.
    private func isDoubaoProcess(_ sourcePID: Int64) -> Bool {
        guard sourcePID > 0, sourcePID <= Int64(Int32.max) else { return false }
        let application = NSRunningApplication(processIdentifier: pid_t(sourcePID))
        return application?.bundleIdentifier == doubaoBundleIdentifier
    }

    /// Starts event-driven precedence recovery plus a low-frequency health check for the long-lived tap.
    ///
    /// Doubao may create a new HID tap when its input source becomes active, so that one transition still
    /// receives a controlled replacement at head priority. The periodic timer only checks whether macOS
    /// disabled the current tap; it never replaces a healthy tap and therefore cannot grow WindowServer's
    /// event-tap chain during normal idle operation.
    private func startEventTapMaintenance() {
        stopEventTapMaintenance()
        lastObservedInputSourceID = InputSourceManager.shared.currentSourceID()
        let notificationName = Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.enabled, self.eventTap != nil else { return }
            let currentSource = InputSourceManager.shared.currentSourceID() ?? "<unknown>"
            guard currentSource != self.lastObservedInputSourceID else { return }
            let previousSource = self.lastObservedInputSourceID ?? "<unknown>"
            self.lastObservedInputSourceID = currentSource
            guard currentSource == doubaoInputSourceID else {
                AppLog.shared.write("input source changed previous=\(previousSource) current=\(currentSource); keeping stable event tap")
                return
            }
            AppLog.shared.write("input source changed previous=\(previousSource) current=\(currentSource); restoring event tap precedence")
            self.scheduleEventTapRearm(reason: "doubao-input-source-activated")
        }

        let timer = Timer(timeInterval: eventTapWatchdogIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self, self.enabled else { return }
            self.performEventTapHealthCheck()
        }
        eventTapWatchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        AppLog.shared.write("event tap maintenance started mode=health-check-only watchdog-interval=\(eventTapWatchdogIntervalSeconds)")
    }

    /// Stops input-source observation and the fallback timer associated with the active listener.
    private func stopEventTapMaintenance() {
        if let observer = inputSourceChangeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            inputSourceChangeObserver = nil
        }
        eventTapWatchdogTimer?.invalidate()
        eventTapWatchdogTimer = nil
        lastObservedInputSourceID = nil
    }

    /// Verifies the current tap without changing its identity or position in WindowServer's event chain.
    ///
    /// CoreGraphics documents that a disabled event tap can normally be recovered by enabling the same
    /// Mach port again. Reusing that port is the cheapest path and preserves a single long-lived tap. A
    /// replacement is scheduled only when the port is missing or remains disabled after the enable call.
    private func performEventTapHealthCheck() {
        guard let tap = eventTap else {
            AppLog.shared.write("event tap health check failed reason=no-active-listener; restarting listener")
            _ = start()
            return
        }
        guard !CGEvent.tapIsEnabled(tap: tap) else { return }

        AppLog.shared.write("event tap health check found disabled tap; re-enabling in place")
        CGEvent.tapEnable(tap: tap, enable: true)
        guard !CGEvent.tapIsEnabled(tap: tap) else {
            AppLog.shared.write("event tap health check recovered existing tap")
            return
        }
        scheduleEventTapRearm(reason: "health-check-reenable-failed")
    }

    /// Queues one main-run-loop event-tap replacement while preserving the current physical hold state.
    private func scheduleEventTapRearm(reason: String) {
        guard pendingEventTapRearm == nil else {
            AppLog.shared.write("event tap rearm already pending reason=\(reason)")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingEventTapRearm != nil else { return }
            self.pendingEventTapRearm = nil
            self.rebuildEventTapPreservingState(reason: reason)
        }
        pendingEventTapRearm = work
        AppLog.shared.write("event tap rearm scheduled reason=\(reason)")
        DispatchQueue.main.async(execute: work)
    }

    /// Replaces the HID event tap at head priority without clearing timers or the inferred pressed state.
    private func rebuildEventTapPreservingState(reason: String) {
        guard eventTap != nil else {
            AppLog.shared.write("event tap rearm skipped reason=no-active-listener trigger=\(reason)")
            return
        }
        guard accessibilityTrusted(prompt: false) else {
            AppLog.shared.write("event tap rearm failed reason=accessibility-not-trusted trigger=\(reason)")
            onStateChange?(false, "需要辅助功能权限")
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let replacementTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            AppLog.shared.write("event tap rearm failed reason=event-tap-create-failed trigger=\(reason)")
            return
        }

        let replacementSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, replacementTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), replacementSource, .commonModes)
        CGEvent.tapEnable(tap: replacementTap, enable: true)

        let previousTap = eventTap
        let previousSource = runLoopSource
        eventTap = replacementTap
        runLoopSource = replacementSource
        invalidateEventTap(previousTap, source: previousSource)
        AppLog.shared.write("event tap rearmed reason=\(reason) pressed=\(triggerPressed)")
    }

    /// Removes an obsolete tap from both the main run loop and CoreGraphics immediately.
    ///
    /// Disabling a tap stops callbacks but does not express that its Mach port and run-loop source are no
    /// longer reusable. Explicit invalidation gives WindowServer a deterministic teardown signal before
    /// Swift releases the final references, preventing replaced taps from lingering in the global chain.
    private func invalidateEventTap(_ tap: CFMachPort?, source: CFRunLoopSource?) {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
    }

    /// Cancels a queued event-tap replacement that has not executed yet.
    private func cancelPendingEventTapRearm(reason: String) {
        guard pendingEventTapRearm != nil else { return }
        pendingEventTapRearm?.cancel()
        pendingEventTapRearm = nil
        AppLog.shared.write("event tap rearm canceled reason=\(reason)")
    }

    /// Cancels a previous timer on key-down and schedules a fresh switch on key-up.
    private func handleTriggerState(_ pressed: Bool) {
        if pressed {
            resetVoiceFallback(sendKeyUp: true, reason: "trigger-pressed")
            cancelPendingReleaseSwitch(reason: "trigger-pressed")
            scheduleVoiceFallbackIfNeeded()
        } else {
            resetVoiceFallback(sendKeyUp: true, reason: "trigger-released")
            // 豆包仍处于选中状态时不会再次发出输入法切换通知。每轮真实松开后恢复监听顺序，
            // 让延迟期间的下一次按下仍可在豆包消费事件之前取消旧计时，不依赖输入法重新激活。
            scheduleEventTapRearm(reason: "trigger-released")
            scheduleReleaseSwitch()
        }
    }

    /// Schedules one supplemental trigger only when Doubao switched in but its voice window never appeared.
    private func scheduleVoiceFallbackIfNeeded() {
        let sourceBeforePress = InputSourceManager.shared.currentSourceID()
        guard sourceBeforePress != doubaoInputSourceID else {
            AppLog.shared.write("voice fallback skipped reason=doubao-already-active")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled, self.triggerPressed else { return }
            self.pendingVoiceFallback = nil
            let currentSource = InputSourceManager.shared.currentSourceID()
            guard currentSource == doubaoInputSourceID else {
                AppLog.shared.write("voice fallback skipped reason=doubao-not-active current=\(currentSource ?? "<unknown>")")
                return
            }
            guard !self.isDoubaoVoiceWindowVisible() else {
                AppLog.shared.write("voice fallback skipped reason=voice-window-visible")
                return
            }

            if self.postSupplementalTrigger(down: true) {
                self.supplementalTriggerDownSent = true
                AppLog.shared.write("voice fallback supplemental keyDown sent delay=\(voiceFallbackCheckDelaySeconds)")
            }
        }
        pendingVoiceFallback = work
        AppLog.shared.write("voice fallback check scheduled delay=\(voiceFallbackCheckDelaySeconds) source-before=\(sourceBeforePress ?? "<unknown>")")
        DispatchQueue.main.asyncAfter(deadline: .now() + voiceFallbackCheckDelaySeconds, execute: work)
    }

    /// Cancels the fallback check and optionally releases a supplemental trigger that was sent earlier.
    private func resetVoiceFallback(sendKeyUp: Bool, reason: String) {
        if pendingVoiceFallback != nil {
            pendingVoiceFallback?.cancel()
            pendingVoiceFallback = nil
            AppLog.shared.write("voice fallback check canceled reason=\(reason)")
        }
        guard supplementalTriggerDownSent else { return }
        if sendKeyUp { _ = postSupplementalTrigger(down: false) }
        supplementalTriggerDownSent = false
        AppLog.shared.write("voice fallback supplemental reset send-key-up=\(sendKeyUp) reason=\(reason)")
    }

    /// Returns whether the small Doubao-owned voice indicator window is currently visible.
    private func isDoubaoVoiceWindowVisible() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        return windows.contains { window in
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let bundleID = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
            guard bundleID == doubaoBundleIdentifier || ownerName.localizedCaseInsensitiveContains("Doubao") || ownerName.contains("豆包") else {
                return false
            }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            return layer > 0 && (70...260).contains(width) && (20...60).contains(height)
        }
    }

    /// Posts one trigger edge at the session layer after Doubao is active, bypassing the global shortcut handler.
    private func postSupplementalTrigger(down: Bool) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(trigger.keyCode),
            keyDown: down
        ) else {
            onError?("无法构造豆包语音补发按键")
            return false
        }

        if trigger.isModifier {
            event.type = .flagsChanged
            event.flags = supplementalModifierFlags(down: down)
        }
        AppLog.shared.write("voice fallback posting supplemental down=\(down) keyCode=\(trigger.keyCode) flags=\(event.flags.rawValue)")
        event.post(tap: .cgSessionEventTap)
        return true
    }

    /// Builds a left/right-aware modifier state for the supplemental trigger event.
    private func supplementalModifierFlags(down: Bool) -> CGEventFlags {
        let nonCoalescedFlag: UInt64 = 0x00000100
        guard down else { return CGEventFlags(rawValue: nonCoalescedFlag) }
        let rawValue = modifierFlag(for: trigger.keyCode).rawValue
            | deviceModifierFlagRaw(for: trigger.keyCode)
            | nonCoalescedFlag
        return CGEventFlags(rawValue: rawValue)
    }

    /// Returns the left/right device-specific flag associated with a modifier key code.
    private func deviceModifierFlagRaw(for keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 54: return 0x00000010
        case 55: return 0x00000008
        case 56: return 0x00000002
        case 60: return 0x00000004
        case 58: return 0x00000020
        case 61: return 0x00000040
        case 59: return 0x00000001
        case 62: return 0x00002000
        default: return 0
        }
    }

    /// Schedules switching to the release input source after the configured delay.
    private func scheduleReleaseSwitch() {
        cancelPendingReleaseSwitch(reason: "rescheduled")
        let delay = configuredReleaseSwitchDelaySeconds()
        let releaseID = UUID()
        pendingReleaseSwitchID = releaseID
        AppLog.shared.write("release switch scheduled delay=\(delay) cycle=\(releaseID)")
        scheduleReleaseSwitchCheck(releaseID: releaseID, delay: delay, waitingForVoiceEnd: false)
    }

    /// Queues a guarded check for one release cycle and keeps active voice input from being interrupted.
    ///
    /// A second press can be swallowed by Doubao without changing the selected input source. The voice
    /// window is an independent signal in that case: after the original deadline, wait for it to close,
    /// then allow a full release delay. A real press cancels this cycle, and a real release replaces it.
    /// All checks and the final TIS selection run on the main queue without a second unchecked hop.
    private func scheduleReleaseSwitchCheck(releaseID: UUID, delay: TimeInterval, waitingForVoiceEnd: Bool) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingReleaseSwitchID == releaseID, self.enabled, !self.triggerPressed else { return }
            if self.isDoubaoVoiceWindowVisible() {
                if !waitingForVoiceEnd {
                    AppLog.shared.write("release switch deferred reason=voice-window-visible cycle=\(releaseID)")
                    self.scheduleEventTapRearm(reason: "release-deadline-during-voice")
                }
                self.scheduleReleaseSwitchCheck(
                    releaseID: releaseID,
                    delay: releaseVoiceRecheckIntervalSeconds,
                    waitingForVoiceEnd: true
                )
                return
            }
            if waitingForVoiceEnd {
                let releaseDelay = configuredReleaseSwitchDelaySeconds()
                AppLog.shared.write("release switch voice ended; restarting delay=\(releaseDelay) cycle=\(releaseID)")
                self.scheduleReleaseSwitchCheck(releaseID: releaseID, delay: releaseDelay, waitingForVoiceEnd: false)
                return
            }
            self.pendingReleaseSwitch = nil
            self.pendingReleaseSwitchID = nil
            self.switchToReleaseInputSource()
        }
        pendingReleaseSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Cancels the queued check and invalidates its cycle before any stale callback can select an input source.
    private func cancelPendingReleaseSwitch(reason: String) {
        guard pendingReleaseSwitchID != nil || pendingReleaseSwitch != nil else { return }
        let releaseID = pendingReleaseSwitchID
        pendingReleaseSwitchID = nil
        pendingReleaseSwitch?.cancel()
        pendingReleaseSwitch = nil
        AppLog.shared.write("release switch canceled reason=\(reason) cycle=\(releaseID?.uuidString ?? "<unknown>")")
    }

    /// Maps a recorded modifier key code to the corresponding event flag.
    private func modifierFlag(for keyCode: UInt16) -> CGEventFlags {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 57: return .maskAlphaShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return []
        }
    }

    /// Switches to the configured input source after the trigger has been released.
    private func switchToReleaseInputSource() {
        guard let inputSourceID = UserDefaults.standard.string(forKey: DefaultsKey.releaseInputSourceID), !inputSourceID.isEmpty else {
            onError?("尚未设置松开后使用的输入法")
            return
        }
        AppLog.shared.write("release switch executing target=\(inputSourceID) current=\(InputSourceManager.shared.currentSourceID() ?? "<unknown>")")
        InputSourceManager.shared.switchTo(id: inputSourceID) { [weak self] error in
            if let error { self?.onError?(error) }
        }
    }
}

private func eventTypeName(_ type: CGEventType) -> String {
    switch type {
    case .keyDown: return "keyDown"
    case .keyUp: return "keyUp"
    case .flagsChanged: return "flagsChanged"
    default: return "type-\(type.rawValue)"
    }
}

private extension Int64 {
    var boolValue: Bool { self != 0 }
}

private final class KeyRecorderButton: NSButton {
    var onRecorded: ((TriggerKey) -> Void)?
    private var monitor: Any?
    private var recording = false

    override func mouseDown(with event: NSEvent) {
        if recording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        recording = true
        title = "请按下一个键…（Esc 取消）"
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                self.stopRecording()
                return nil
            }

            if event.type == .flagsChanged, KeyName.isModifier(event.keyCode) {
                let key = TriggerKey(keyCode: event.keyCode, isModifier: true, displayName: KeyName.name(for: event.keyCode, event: event))
                self.finish(with: key)
                return nil
            }

            if event.type == .keyDown {
                let key = TriggerKey(keyCode: event.keyCode, isModifier: false, displayName: KeyName.name(for: event.keyCode, event: event))
                self.finish(with: key)
                return nil
            }
            return event
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        title = "当前按键：\(TriggerKey.load().displayName)（点击修改）"
    }

    private func finish(with key: TriggerKey) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        key.save()
        title = "当前按键：\(key.displayName)（点击修改）"
        onRecorded?(key)
    }
}

private enum KeyName {
    private static let special: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "空格", 51: "Delete", 53: "Esc",
        55: "左 Command", 54: "右 Command", 56: "左 Shift", 60: "右 Shift",
        57: "Caps Lock", 58: "左 Option", 61: "右 Option", 59: "左 Control",
        62: "右 Control", 63: "Fn", 71: "小键盘 Clear", 76: "小键盘 Enter",
        115: "Home", 116: "Page Up", 117: "向前删除", 119: "End", 121: "Page Down",
        123: "左方向键", 124: "右方向键", 125: "下方向键", 126: "上方向键",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20"
    ]

    static func isModifier(_ keyCode: UInt16) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    static func name(for keyCode: UInt16, event: NSEvent) -> String {
        if let known = special[keyCode] { return known }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return characters.uppercased()
        }
        return "按键 \(keyCode)"
    }
}

private final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let releasePopup = NSPopUpButton()
    /// Text field used to edit the release switch delay in seconds.
    private let releaseDelayField = NSTextField()
    /// Stepper used to adjust the release switch delay without typing.
    private let releaseDelayStepper = NSStepper()
    private let keyRecorder = KeyRecorderButton()
    private let enabledCheckbox = NSButton(checkboxWithTitle: "启用松开后自动切回", target: nil, action: nil)
    /// Checkbox that controls whether the app launches automatically after login.
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "开机自动启动", target: nil, action: nil)
    private let permissionLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "豆包语音自动切回 - 设置"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadSettings()
        refreshSources(reloadController: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        loadSettings()
        refreshSources()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateStatus(isListening: Bool, text: String) {
        statusLabel.stringValue = "监听状态：\(text)"
        statusLabel.textColor = isListening ? .systemGreen : .systemOrange
        permissionLabel.stringValue = accessibilityTrusted(prompt: false)
            ? "辅助功能权限：已授权"
            : "辅助功能权限：未授权（全局按键监听需要此权限）"
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "豆包语音结束后自动切回输入法")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "豆包负责按下时切换并开始语音；本工具监听真实松开，并在未出现语音浮层时补发一次按键。")
        subtitle.textColor = .secondaryLabelColor

        let releaseLabel = NSTextField(labelWithString: "切回的输入法")
        let releaseDelayLabel = NSTextField(labelWithString: "松开后延迟切回")
        releaseLabel.font = .systemFont(ofSize: 13, weight: .medium)
        releaseDelayLabel.font = .systemFont(ofSize: 13, weight: .medium)

        releasePopup.target = self
        releasePopup.action = #selector(selectionChanged(_:))
        releasePopup.widthAnchor.constraint(equalToConstant: 310).isActive = true

        releaseDelayField.delegate = self
        releaseDelayField.target = self
        releaseDelayField.action = #selector(releaseDelayChanged(_:))
        releaseDelayField.placeholderString = "0.10"
        releaseDelayField.widthAnchor.constraint(equalToConstant: 86).isActive = true
        releaseDelayStepper.minValue = minimumReleaseSwitchDelaySeconds
        releaseDelayStepper.maxValue = maximumReleaseSwitchDelaySeconds
        releaseDelayStepper.increment = 0.1
        releaseDelayStepper.target = self
        releaseDelayStepper.action = #selector(releaseDelayChanged(_:))

        let refreshButton = NSButton(title: "刷新输入法列表", target: self, action: #selector(refreshClicked))
        let permissionButton = NSButton(title: "授予/检查辅助功能权限", target: self, action: #selector(permissionClicked))
        let openSettingsButton = NSButton(title: "打开系统设置", target: self, action: #selector(openPrivacySettings))

        keyRecorder.bezelStyle = .rounded
        keyRecorder.onRecorded = { key in
            HotKeyController.shared.reloadSettings(
                ignoreNextModifierReleaseFor: key.isModifier ? key.keyCode : nil
            )
        }
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(toggleChanged(_:))
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleChanged(_:))

        permissionLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        let tip = NSTextField(wrappingLabelWithString: "请先在豆包输入法中开启“全局唤起语音”，并确保长按快捷键与这里一致。本工具不拦截按键，只在语音未启动时补发一次。")
        tip.textColor = .secondaryLabelColor
        tip.font = .systemFont(ofSize: 11)

        let releaseDelayStack = NSStackView(views: [releaseDelayField, NSTextField(labelWithString: "秒"), releaseDelayStepper])
        releaseDelayStack.orientation = .horizontal
        releaseDelayStack.alignment = .centerY
        releaseDelayStack.spacing = 8

        let sourceGrid = NSGridView(views: [
            [releaseLabel, releasePopup],
            [releaseDelayLabel, releaseDelayStack]
        ])
        sourceGrid.rowSpacing = 10
        sourceGrid.columnSpacing = 16
        sourceGrid.column(at: 0).xPlacement = .trailing

        let permissionButtons = NSStackView(views: [permissionButton, openSettingsButton])
        permissionButtons.orientation = .horizontal
        permissionButtons.spacing = 8

        let stack = NSStackView(views: [
            title, subtitle, sourceGrid, refreshButton, horizontalLine(), keyRecorder,
            enabledCheckbox, launchAtLoginCheckbox, horizontalLine(), permissionLabel,
            statusLabel, permissionButtons, tip
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            subtitle.widthAnchor.constraint(equalToConstant: 500),
            tip.widthAnchor.constraint(equalToConstant: 500),
            sourceGrid.widthAnchor.constraint(equalToConstant: 500)
        ])
    }

    private func horizontalLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return box
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        keyRecorder.title = "当前按键：\(TriggerKey.load().displayName)（点击修改）"
        enabledCheckbox.state = (defaults.object(forKey: DefaultsKey.enabled) == nil || defaults.bool(forKey: DefaultsKey.enabled)) ? .on : .off
        syncLaunchAtLoginCheckbox()
        syncReleaseDelayControls(configuredReleaseSwitchDelaySeconds())
        let trusted = accessibilityTrusted(prompt: false)
        updateStatus(isListening: trusted, text: trusted ? (enabledCheckbox.state == .on ? "运行中" : "已暂停") : "需要辅助功能权限")
    }

    /// Refreshes popup contents and optionally propagates the selected values to the active listener.
    ///
    /// Initial window construction runs before AppDelegate starts the listener, so that path persists the
    /// default selection without starting an early Event Tap. Interactive refreshes keep the existing
    /// behavior and reload controller settings after the popup has been updated.
    private func refreshSources(reloadController: Bool = true) {
        let sources = InputSourceManager.shared.refresh()
        let defaults = UserDefaults.standard
        let savedRelease = defaults.string(forKey: DefaultsKey.releaseInputSourceID)

        populate(releasePopup, sources: sources)

        select(popup: releasePopup, savedID: savedRelease, preferredNames: ["微信", "WeChat", "Weixin"])
        saveSelections(reloadController: reloadController)
    }

    private func populate(_ popup: NSPopUpButton, sources: [InputSourceInfo]) {
        popup.removeAllItems()
        if sources.isEmpty {
            popup.addItem(withTitle: "未发现可用输入法")
            popup.isEnabled = false
            return
        }
        popup.isEnabled = true
        for source in sources {
            popup.addItem(withTitle: source.name)
            popup.lastItem?.representedObject = source.id
            popup.lastItem?.toolTip = source.id
        }
    }

    private func select(popup: NSPopUpButton, savedID: String?, preferredNames: [String]) {
        if let savedID, let item = popup.itemArray.first(where: { ($0.representedObject as? String) == savedID }) {
            popup.select(item)
            return
        }
        if let item = popup.itemArray.first(where: { item in
            preferredNames.contains { item.title.localizedCaseInsensitiveContains($0) }
        }) {
            popup.select(item)
        }
    }

    /// Persists the popup selection and reloads runtime settings only when a listener already owns them.
    private func saveSelections(reloadController: Bool = true) {
        if let id = releasePopup.selectedItem?.representedObject as? String {
            UserDefaults.standard.set(id, forKey: DefaultsKey.releaseInputSourceID)
        }
        if reloadController {
            HotKeyController.shared.reloadSettings()
        }
    }

    @objc private func selectionChanged(_ sender: NSPopUpButton) { saveSelections() }
    @objc private func refreshClicked() { refreshSources() }

    /// Persists the release delay from either the text field or the stepper.
    @objc private func releaseDelayChanged(_ sender: NSControl) {
        if sender === releaseDelayStepper {
            persistReleaseDelay(releaseDelayStepper.doubleValue, refreshTextField: true)
            return
        }
        commitReleaseDelayFromTextField(refreshTextField: true)
    }

    /// Persists valid delay edits while the user is typing.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === releaseDelayField {
            commitReleaseDelayFromTextField(refreshTextField: false)
        }
    }

    /// Persists text edits when a delay field loses focus.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === releaseDelayField {
            commitReleaseDelayFromTextField(refreshTextField: true)
        }
    }

    /// Reads the release delay field and saves it when it contains a valid number.
    private func commitReleaseDelayFromTextField(refreshTextField: Bool) {
        let normalized = releaseDelayField.stringValue.replacingOccurrences(of: ",", with: ".")
        guard let rawValue = TimeInterval(normalized) else {
            if refreshTextField { syncReleaseDelayControls(configuredReleaseSwitchDelaySeconds()) }
            return
        }
        persistReleaseDelay(rawValue, refreshTextField: refreshTextField)
    }

    /// Saves a release delay and keeps related controls in sync.
    private func persistReleaseDelay(_ rawValue: TimeInterval, refreshTextField: Bool) {
        let value = clampedReleaseSwitchDelay(rawValue)
        UserDefaults.standard.set(value, forKey: DefaultsKey.releaseSwitchDelaySeconds)
        releaseDelayStepper.doubleValue = value
        if refreshTextField { releaseDelayField.stringValue = formatDelaySeconds(value) }
        HotKeyController.shared.reloadSettings()
    }

    /// Updates release delay controls without changing the stored value.
    private func syncReleaseDelayControls(_ value: TimeInterval) {
        let clamped = clampedReleaseSwitchDelay(value)
        releaseDelayField.stringValue = formatDelaySeconds(clamped)
        releaseDelayStepper.doubleValue = clamped
    }

    /// Updates the login item checkbox from the current system registration status.
    private func syncLaunchAtLoginCheckbox() {
        launchAtLoginCheckbox.state = LoginItemManager.shared.isEnabled ? .on : .off
        launchAtLoginCheckbox.toolTip = "开机自动启动：\(LoginItemManager.shared.statusDescription())"
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        if sender === enabledCheckbox {
            UserDefaults.standard.set(sender.state == .on, forKey: DefaultsKey.enabled)
        } else if sender === launchAtLoginCheckbox {
            if let error = LoginItemManager.shared.setEnabled(sender.state == .on) {
                statusLabel.stringValue = error
                statusLabel.textColor = .systemOrange
            }
            syncLaunchAtLoginCheckbox()
        }
        HotKeyController.shared.reloadSettings()
    }

    @objc private func permissionClicked() {
        _ = accessibilityTrusted(prompt: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            let started = HotKeyController.shared.start()
            self?.updateStatus(isListening: started, text: started ? "运行中" : "等待授权；授权后请重启软件")
        }
    }

    @objc private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func windowWillClose(_ notification: Notification) {
        commitReleaseDelayFromTextField(refreshTextField: true)
        keyRecorder.stopRecording()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: SettingsWindowController!
    private let statusMenuItem = NSMenuItem(title: "状态：正在启动…", action: nil, keyEquivalent: "")
    private let enabledMenuItem = NSMenuItem(title: "启用松开后自动切回", action: #selector(toggleEnabled), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerDefaults()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "<unknown>"
        AppLog.shared.write("app launch version=\(appVersion) args=\(CommandLine.arguments.joined(separator: " "))")
        InputSourceManager.shared.refresh()
        settingsWindow = SettingsWindowController()
        setupMainMenu()
        setupStatusItem()

        HotKeyController.shared.onStateChange = { [weak self] listening, text in
            self?.updateStatusMenu(listening: listening, text: text)
            self?.settingsWindow.updateStatus(isListening: listening, text: text)
        }
        HotKeyController.shared.onError = { [weak self] message in self?.showTransientError(message) }

        let started = HotKeyController.shared.start()
        let initialStatus = started ? (UserDefaults.standard.bool(forKey: DefaultsKey.enabled) ? "运行中" : "已暂停") : "需要辅助功能权限"
        updateStatusMenu(listening: started, text: initialStatus)
        settingsWindow.show()
    }

    /// Shows settings when Finder opens the app while it is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            DefaultsKey.enabled: true,
            DefaultsKey.releaseSwitchDelaySeconds: defaultReleaseSwitchDelaySeconds
        ])
        if UserDefaults.standard.object(forKey: DefaultsKey.triggerKeyCode) == nil {
            TriggerKey.defaultKey.save()
        }
    }

    /// Installs the standard edit menu so text fields receive Command-A/C/V/X shortcuts.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: "豆包语音自动切回")
            button.toolTip = "豆包语音自动切回"
        }

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        enabledMenuItem.target = self
        menu.addItem(enabledMenuItem)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let switchRelease = NSMenuItem(title: "立即切到“自动切回”输入法", action: #selector(switchToRelease), keyEquivalent: "")
        switchRelease.target = self
        menu.addItem(switchRelease)
        let openLogItem = NSMenuItem(title: "打开诊断日志", action: #selector(openDiagnosticLog), keyEquivalent: "")
        openLogItem.target = self
        menu.addItem(openLogItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
        syncEnabledMenu()
    }

    private func updateStatusMenu(listening: Bool, text: String) {
        statusMenuItem.title = "状态：\(text)"
        statusItem.button?.contentTintColor = listening ? nil : .systemOrange
        syncEnabledMenu()
    }

    private func syncEnabledMenu() {
        enabledMenuItem.state = UserDefaults.standard.bool(forKey: DefaultsKey.enabled) ? .on : .off
    }

    @objc private func toggleEnabled() {
        let newValue = !UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
        UserDefaults.standard.set(newValue, forKey: DefaultsKey.enabled)
        HotKeyController.shared.reloadSettings()
        syncEnabledMenu()
    }

    @objc private func openSettings() { settingsWindow.show() }

    @objc private func switchToRelease() {
        switchUsingDefaultsKey(DefaultsKey.releaseInputSourceID)
    }

    @objc private func openDiagnosticLog() {
        NSWorkspace.shared.open(AppLog.shared.fileURL)
    }

    private func switchUsingDefaultsKey(_ key: String) {
        guard let id = UserDefaults.standard.string(forKey: key) else {
            showTransientError("请先在设置中选择输入法")
            return
        }
        InputSourceManager.shared.switchTo(id: id) { [weak self] error in
            if let error { self?.showTransientError(error) }
        }
    }

    private func showTransientError(_ message: String) {
        statusMenuItem.title = "错误：\(message)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.updateStatusMenu(listening: accessibilityTrusted(prompt: false), text: UserDefaults.standard.bool(forKey: DefaultsKey.enabled) ? "运行中" : "已暂停")
        }
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
