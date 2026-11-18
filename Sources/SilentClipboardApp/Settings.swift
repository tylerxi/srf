import AppKit
import SwiftUI
import ClipboardCore

@MainActor final class SettingsModel: ObservableObject {
    @Published var configuration = Configuration()
    @Published var token = ""
    @Published var message = "正在读取配置…"
    @Published var busy = false
    @Published var running = false
    @Published var keySaved = false
    @Published var clipboardAllowed = false
    @Published var outputAllowed = false
    @Published var shortcutsReady = false
    @Published var success = false

    private func call(_ request: ControlRequest) async throws -> ControlResponse {
        try await Task.detached(priority: .userInitiated) { try SocketIO.client(request) }.value
    }
    private func launchWorker() async throws {
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("SilentClipboard.app")
        let url = FileManager.default.fileExists(atPath: sibling.path)
            ? sibling : URL(fileURLWithPath: "/Applications/SilentClipboard.app")
        let options = NSWorkspace.OpenConfiguration(); options.activates = false; options.hides = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: options)
        for _ in 0..<30 {
            if (try? await call(ControlRequest(command: "status"))) != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ControlError.unavailable
    }
    private func restartWorker() async throws {
        // CGPreflightPostEventAccess is cached by the running process. A restart
        // is required after the user changes Accessibility permission in System
        // Settings; merely polling the old process keeps returning false.
        _ = try? await call(ControlRequest(command: "quit"))
        try await Task.sleep(for: .milliseconds(500))
        try await launchWorker()
    }
    func load() async {
        busy = true; defer { busy = false }
        do {
            if (try? await call(ControlRequest(command: "status"))) == nil { try await launchWorker() }
            let result = try await call(ControlRequest(command: "status"))
            configuration = result.configuration ?? (try? AppPaths.loadConfiguration()) ?? Configuration()
            update(result)
            message = keySaved ? "配置已载入。修改后保存即可生效。" : "填写 API 密钥并保存，即可开始使用。"
            success = keySaved
        } catch { running = false; success = false; message = "无法启动静默工具，请确认它与设置应用安装在同一目录。" }
    }
    private func update(_ result: ControlResponse) {
        running = result.pid != nil
        keySaved = result.credentialAvailable == true
        clipboardAllowed = result.clipboardAccess == "allowed"
        outputAllowed = result.outputAccess == true
        shortcutsReady = result.hotkeyRegistered == true && result.outputHotkeyRegistered == true
    }
    func save() async {
        busy = true; defer { busy = false }
        do {
            try configuration.validate()
            let result = try await call(ControlRequest(command: "configure", value: token.isEmpty ? nil : token, configuration: configuration))
            guard result.ok else { message = friendly(result.message); success = false; return }
            token = ""
            let state = try await call(ControlRequest(command: "status")); update(state)
            success = true; message = "已保存并立即生效。关闭这个窗口后，静默工具会继续运行。"
        } catch { success = false; message = error is PipelineError ? "请检查完整 HTTPS 地址、模型和提示词。" : "保存失败，请检查静默工具是否正在运行。" }
    }
    func test() async {
        busy = true; success = false; message = "正在测试连接…"; defer { busy = false }
        do {
            try configuration.validate()
            let reply = try await call(ControlRequest(command: "verify", value: token.isEmpty ? nil : token, configuration: configuration))
            guard reply.ok else { message = friendly(reply.message); return }
            let deadline = ContinuousClock.now.advanced(by: .seconds(configuration.timeoutSeconds + 5))
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(400))
                let result = try await call(ControlRequest(command: "verify-status"))
                if result.message != "running" {
                    success = result.ok
                    message = result.ok ? "连接成功，已收到测试回复。需要保留修改时，请点击保存。" : friendly(result.message)
                    return
                }
            }
            message = "连接超时，请检查 API 地址和网络。"
        } catch { message = error is PipelineError ? "请检查完整 HTTPS 地址、模型和提示词。" : "测试失败，请确认静默工具正在运行。" }
    }
    func authorize(_ command: String) async {
        busy = true; defer { busy = false }
        if command == "authorize-output" {
            let result = try? await call(ControlRequest(command: command))
            if result?.ok != true {
                // Only this deliberately clicked setup button may open system settings.
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                message = "请在“辅助功能”中勾选“静默剪贴板”（添加的是后台应用，不是设置应用）。完成后回到这里点击“刷新并重启”。"
            } else {
                message = "已检测到文字输出权限，正在重启后台工具…"
            }
            do {
                try await restartWorker()
                let state = try await call(ControlRequest(command: "status")); update(state)
                success = outputAllowed
                message = outputAllowed ? "文字输出权限已生效。" : "仍未检测到权限：请确认辅助功能列表中的项目是 /Applications/SilentClipboard.app。"
            } catch {
                success = false; message = "无法重启后台工具，请关闭后重新打开设置。"
            }
            return
        }
        _ = try? await call(ControlRequest(command: command))
        if let state = try? await call(ControlRequest(command: "status")) { update(state) }
        success = false; message = "剪贴板权限检查完成。"
    }
    func refresh() async {
        busy = true; defer { busy = false }
        do {
            try await restartWorker()
            let result = try await call(ControlRequest(command: "status"))
            update(result); success = clipboardAllowed && outputAllowed && shortcutsReady
            message = success ? "权限和快捷键已就绪。" : "请在辅助功能中允许 /Applications/SilentClipboard.app，然后再次点击刷新并重启。"
        } catch { running = false; success = false; message = "静默工具未运行，正在重新启动失败；请重新打开设置。" }
    }
    private func friendly(_ code: String) -> String {
        switch code {
        case "key_missing", "keychain_unavailable": "未找到可用密钥，请重新输入并保存。"
        case "http_401", "http_403": "认证失败，请检查 API 密钥和访问权限。"
        case "http_402": "账户余额不足，请检查 API 账户。"
        case "http_429": "请求过于频繁，请稍后测试。"
        case "http_404": "接口不存在，请填写完整的 Chat Completions 地址。"
        case "hotkey_conflict": "发送快捷键被其他应用占用，请先解除冲突。"
        case "unexpected_answer": "已收到回复，但测试文字不匹配，请检查模型接口。"
        case "invalid_configuration", "invalid_configuration_or_write_failed": "配置无效或无法写入，请检查地址、模型和提示词。"
        case "verification_running": "已有连接测试正在进行，请稍后再试。"
        case "timeout", "network_error": "连接超时或网络不可用，请检查 API 地址和网络。"
        default: "测试未成功（\(code)），请检查接口是否兼容 Chat Completions。"
        }
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("静默剪贴板").font(.system(size: 25, weight: .semibold))
                    Text("配置一次，关掉窗口后继续静默运行。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.running ? "工具运行中" : "工具未运行", systemImage: model.running ? "circle.fill" : "circle")
                    .font(.system(size: 11)).foregroundStyle(model.running ? .green : .secondary)
                    .padding(.top, 8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    field("API 地址") { TextField("https://api.deepseek.com/chat/completions", text: $model.configuration.apiEndpoint).accessibilityIdentifier("endpoint") }
                    Text("填写完整 HTTPS 接口地址；支持 Chat Completions 格式。")
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 88)
                    field("模型") { TextField("deepseek-flash", text: $model.configuration.model).accessibilityIdentifier("model") }
                    field("触发关键字") { TextField("!!!", text: $model.configuration.triggerPrefix).accessibilityIdentifier("triggerPrefix") }
                    Text("剪贴板文字必须以此关键字开头；发送前会移除它。")
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 88)
                    field("API 密钥") { SecureField(model.keySaved ? "已保存 · 留空保留现有密钥" : "输入 API Token", text: $model.token).accessibilityIdentifier("token") }
                    Text("密钥保存在 macOS 钥匙串中。")
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 88)
                }.padding(12)
            } label: { Text("连接").font(.headline) }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.configuration.systemPrompt)
                        .font(.system(size: 13)).frame(height: 102)
                        .padding(5).background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                        .accessibilityIdentifier("prompt")
                    Text("每次请求都会附带此提示词。可写角色、常用资料，或“答案不超过 30 个字符”。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("字数提示由模型遵循，不会强制截断答案。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            } label: { Text("默认提示词").font(.headline) }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("⌘C 复制以关键字开头的文字 → ⌃C 发送 → ⌃V 逐次输出")
                        .font(.system(size: 12, weight: .medium))
                    Text("每次两个字符，耗尽后输出 ..。等待或失败时无动作。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button(model.clipboardAllowed ? "剪贴板已允许" : "允许剪贴板访问") { Task { await model.authorize("authorize") } }
                    .disabled(model.clipboardAllowed || model.busy)
                Button(model.outputAllowed ? "文字输出已允许" : "允许文字输出（辅助功能）") { Task { await model.authorize("authorize-output") } }
                    .disabled(model.outputAllowed || model.busy)
                Button("刷新并重启") { Task { await model.refresh() } }.disabled(model.busy)
            }.controlSize(.small)
            Divider()
            HStack(alignment: .center, spacing: 12) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message).font(.system(size: 12))
                    .foregroundStyle(model.success ? Color(nsColor: .systemGreen) : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("result")
                Button("测试连接") { Task { await model.test() } }.disabled(model.busy)
                    .accessibilityIdentifier("test")
                Button("保存并生效") { Task { await model.save() } }.buttonStyle(.borderedProminent)
                    .disabled(model.busy).keyboardShortcut("s", modifiers: .command).accessibilityIdentifier("save")
            }.frame(minHeight: 44)
        }
        .textFieldStyle(.roundedBorder).padding(26).frame(width: 690)
        .task { await model.load() }
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 76, alignment: .trailing)
            content()
        }
    }
}

@MainActor private final class SettingsDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: content)
        window.title = "静默剪贴板 · 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor enum SettingsLauncher {
    static func run() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = NSMenu(); let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出设置", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem); app.mainMenu = menu
        let delegate = SettingsDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
