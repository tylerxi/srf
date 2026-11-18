import Foundation
import Security
import LocalAuthentication
import ClipboardCore
import Darwin

enum AppPaths {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SilentClipboard", isDirectory: true)
    static let socket = directory.appendingPathComponent("control.sock").path
    static let config = directory.appendingPathComponent("config.json")
    static let textReplacementsDatabase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/KeyboardServices/TextReplacements.db")
    static let textReplacementManifest = directory.appendingPathComponent("text-replacements.json")
    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else { throw ControlError.failed }
        guard chmod(directory.path, 0o700) == 0 else { throw ControlError.failed }
    }
    static func loadConfiguration() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: config.path) else { return Configuration() }
        let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: config))
        try value.validate()
        return value
    }
    static func saveConfiguration(_ value: Configuration) throws {
        try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: config, options: .atomic)
        guard chmod(config.path, 0o600) == 0 else { throw ControlError.failed }
    }
}

enum CredentialStore {
    private static var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.bear.silentclipboard.deepseek",
         kSecAttrAccount as String: "api-key",
         kSecUseAuthenticationContext as String: context]
    }
    static func read() throws -> String {
        // Also suppress legacy login-keychain ACL prompts in this process.
        SecKeychainSetUserInteractionAllowed(false)
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw PipelineError.missingCredential }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { throw PipelineError.credentialUnavailable }
        return value
    }
    static func save(_ value: String) throws {
        SecKeychainSetUserInteractionAllowed(false)
        guard (1...4096).contains(value.utf8.count),
              value.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline })
        else { throw PipelineError.missingCredential }
        // Explicit replacement also refreshes the item's access control for an
        // ad-hoc rebuild. Updating its value alone preserves the old code ACL.
        // This is never called by ordinary startup, status or a hotkey.
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw PipelineError.credentialUnavailable }
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrLabel as String] = "SilentClipboard DeepSeek API Key"
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw PipelineError.credentialUnavailable }
        guard try read() == value else { throw PipelineError.credentialUnavailable }
    }
}

final class InstanceLock {
    private let fd: Int32
    init() throws {
        fd = open(AppPaths.directory.appendingPathComponent("instance.lock").path,
                  O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ControlError.failed }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ControlError.alreadyRunning }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
