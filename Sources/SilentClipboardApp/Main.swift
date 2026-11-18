import AppKit
import Darwin
import ClipboardCore

@main struct SilentClipboardMain {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--settings") || Bundle.main.bundleIdentifier == "com.bear.silentclipboard.settings" {
            SettingsLauncher.run(); return
        }
        if arguments.first == "--ctl" { runControl(Array(arguments.dropFirst())); return }
        if arguments.contains("--help") {
            print("SilentClipboard: start without arguments, or --ctl help")
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func runControl(_ arguments: [String]) {
        guard let command = arguments.first, command != "help" else {
            print("""
            srf status | process | pause | resume | cancel | quit
            srf set-key                 Read the API key securely from terminal/stdin
            srf authorize               Explicit clipboard permission setup (may show system UI)
            srf authorize-output        Explicit text output permission setup
            srf settings                Open the separate settings application
            srf configure FILE          Load nonsecret JSON configuration
            srf verify | verify-status  Fixed API smoke test; does not read/write clipboard
            srf login-enable | login-disable
            """)
            return
        }
        if command == "settings" {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/SilentClipboard Settings.app")); return
        }
        var request = ControlRequest(command: command)
        do {
            if command == "set-key" {
                if isatty(STDIN_FILENO) != 0 {
                    var buffer = [CChar](repeating: 0, count: 4097)
                    guard readpassphrase("DeepSeek API key: ", &buffer, buffer.count, 0) != nil else { throw ControlError.failed }
                    request.value = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    for index in buffer.indices { buffer[index] = 0 }
                } else {
                    request.value = readLine(strippingNewline: true)
                }
            } else if command == "configure" {
                guard arguments.count == 2 else { throw ControlError.failed }
                request.configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
                try request.configuration?.validate()
            }
            let response = try SocketIO.client(request)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(response), as: UTF8.self))
            if !response.ok { exit(1) }
        } catch {
            // Never print a Codable, network or keychain error with associated content.
            fputs("Control failed. Check that SilentClipboard.app is running and the command/configuration is valid.\n", stderr)
            exit(1)
        }
    }
}
