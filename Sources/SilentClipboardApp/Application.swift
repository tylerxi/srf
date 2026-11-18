import AppKit
import ServiceManagement
import ClipboardCore

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let clipboard = SystemClipboard()
    private var coordinator: RequestCoordinator!
    private var hotkey: HotKeyService!
    private var outputHotkey: HotKeyService!
    private var server: ControlServer?
    private var instanceLock: InstanceLock?
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var sessionGate = SessionGate()
    private var configError = false
    private var verificationTask: Task<Void, Never>?
    private var verification = "not_run"
    private var verificationID: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        do {
            try AppPaths.prepare()
            instanceLock = try InstanceLock()
            let config: Configuration
            do { config = try AppPaths.loadConfiguration() }
            catch { config = Configuration(); configError = true }
            coordinator = RequestCoordinator(clipboard: clipboard, client: DeepSeekClient(),
                                             configuration: config, credential: CredentialStore.read)
            if configError { coordinator.setPaused(true) }
            hotkey = HotKeyService { [weak self] in self?.trigger() }
            hotkey.register(config)
            outputHotkey = HotKeyService(id: 2) { [weak self] in
                guard let self, !self.sessionGate.suspended, !self.configError else { return }
                self.coordinator.outputNext(using: TextOutput.send)
            }
            outputHotkey.register(code: 9, modifiers: 0x1000) // Control+V
            server = try ControlServer { [weak self] request in
                self?.handle(request) ?? ControlResponse(ok: false, message: "unavailable")
            }
            watchLifecycle()
        } catch { NSApp.terminate(nil) } // No error window even during failed startup.
    }

    private func trigger() {
        guard !sessionGate.suspended, !configError else { return }
        coordinator.trigger()
    }
    private func watchLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        let transitions: [(Notification.Name, SessionGate.Reason, Bool)] = [
            (NSWorkspace.willSleepNotification, .sleeping, true),
            (NSWorkspace.didWakeNotification, .sleeping, false),
            (NSWorkspace.screensDidSleepNotification, .displaySleeping, true),
            (NSWorkspace.screensDidWakeNotification, .displaySleeping, false),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession, false),
            (NSWorkspace.willPowerOffNotification, .shuttingDown, true)
        ]
        for (name, reason, active) in transitions {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.transition(reason, active: active) }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.transition(.locked, active: locked) }
            })
        }
    }
    private func transition(_ reason: SessionGate.Reason, active: Bool) {
        sessionGate.set(reason, active: active)
        guard active else { return }
        coordinator.cancel(reason: "suspended")
        hotkey.resetPressedState()
        outputHotkey.resetPressedState()
        verificationID &+= 1
        verificationTask?.cancel(); verificationTask = nil
        if verification == "running" { verification = "cancelled" }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.cancel(); verificationTask?.cancel(); hotkey?.stop(); outputHotkey?.stop(); server = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.command {
        case "status":
            var result = ControlResponse(ok: !configError, message: configError ? "invalid_configuration" : "running")
            result.pipeline = coordinator.status
            result.clipboardAccess = clipboard.accessName
            result.hotkeyRegistered = hotkey.registered
            result.hotkeyError = hotkey.lastError
            result.outputHotkeyRegistered = outputHotkey.registered
            result.outputAccess = TextOutput.allowed
            result.credentialAvailable = (try? CredentialStore.read()) != nil
            result.configuration = coordinator.configuration
            result.windowCount = NSApp.windows.count
            result.activationPolicy = NSApp.activationPolicy() == .prohibited ? "prohibited" : "unexpected"
            result.loginStatus = String(describing: SMAppService.mainApp.status)
            result.pid = getpid()
            return result
        case "process":
            trigger(); return ControlResponse(ok: !sessionGate.suspended && !configError, message: "triggered", pipeline: coordinator.status)
        case "pause": coordinator.setPaused(true); return ControlResponse(ok: true, message: "paused")
        case "resume":
            guard !configError else { return ControlResponse(ok: false, message: "invalid_configuration") }
            coordinator.setPaused(false); return ControlResponse(ok: true, message: "resumed")
        case "cancel": coordinator.cancel(); return ControlResponse(ok: true, message: "cancelled")
        case "quit":
            coordinator.cancel(); hotkey.stop(); outputHotkey.stop()
            Task { try? await Task.sleep(for: .milliseconds(200)); NSApp.terminate(nil) }
            return ControlResponse(ok: true, message: "quitting")
        case "set-key":
            do { try CredentialStore.save(request.value ?? ""); return ControlResponse(ok: true, message: "key_saved") }
            catch { return ControlResponse(ok: false, message: (error as? PipelineError)?.code ?? "keychain_unavailable") }
        case "authorize":
            // Explicit setup only. Authorization may cause a system-owned dialog.
            clipboard.authorizeInteractively()
            return ControlResponse(ok: clipboard.accessAllowed, message: "authorization_checked", clipboardAccess: clipboard.accessName)
        case "authorize-output":
            return ControlResponse(ok: CGRequestPostEventAccess(), message: "output_authorization_checked")
        case "configure":
            guard let config = request.configuration else { return ControlResponse(ok: false, message: "invalid_configuration") }
            do {
                try config.validate()
                coordinator.cancel(); hotkey.register(config)
                guard hotkey.registered else {
                    let code = hotkey.lastError
                    hotkey.register(coordinator.configuration)
                    return ControlResponse(ok: false, message: "hotkey_conflict", hotkeyError: code)
                }
                do {
                    try AppPaths.saveConfiguration(config)
                    if let key = request.value, !key.isEmpty { try CredentialStore.save(key) }
                } catch {
                    try? AppPaths.saveConfiguration(coordinator.configuration)
                    hotkey.register(coordinator.configuration); throw error
                }
                coordinator.configuration = config; configError = false
                return ControlResponse(ok: true, message: "configured")
            } catch { return ControlResponse(ok: false, message: "invalid_configuration_or_write_failed") }
        case "login-enable", "login-disable":
            do {
                if request.command == "login-enable" { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                return ControlResponse(ok: true, message: "login_updated")
            } catch { return ControlResponse(ok: false, message: "login_update_failed") }
        case "verify":
            guard !sessionGate.suspended else { return ControlResponse(ok: false, message: "suspended") }
            guard verificationTask == nil else { return ControlResponse(ok: false, message: "verification_running") }
            verificationID &+= 1
            let id = verificationID
            verification = "running"
            let config = request.configuration ?? coordinator.configuration
            do { try config.validate() } catch {
                verification = "invalid_configuration"
                return ControlResponse(ok: false, message: verification)
            }
            let suppliedKey = request.value
            verificationTask = Task { [weak self] in
                do {
                    let key = try suppliedKey.flatMap { $0.isEmpty ? nil : $0 } ?? CredentialStore.read()
                    var small = config; small.maxOutputTokens = 64
                    small.systemPrompt = "这是连接测试。只按用户要求返回固定测试文字。"
                    let result = try await DeepSeekClient().answer(text: "只输出 SILENT_CLIPBOARD_OK，不要输出其他内容。", key: key, configuration: small)
                    guard let self, self.verificationID == id, !Task.isCancelled else { return }
                    self.verification = result.trimmingCharacters(in: .whitespacesAndNewlines) == "SILENT_CLIPBOARD_OK" ? "passed" : "unexpected_answer"
                } catch {
                    guard let self, self.verificationID == id else { return }
                    self.verification = (error as? PipelineError)?.code ?? "cancelled"
                }
                self?.verificationTask = nil
            }
            return ControlResponse(ok: true, message: "verification_started_without_reading_clipboard")
        case "verify-status": return ControlResponse(ok: verification == "passed", message: verification)
        default: return ControlResponse(ok: false, message: "unknown_command")
        }
    }
}
