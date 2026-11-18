import Foundation

public struct Configuration: Codable, Sendable, Equatable {
    public var apiEndpoint = "https://api.deepseek.com/chat/completions"
    public var model = "deepseek-flash"
    public var triggerPrefix = "!!!"
    public var systemPrompt = "直接回答用户的问题，使用与问题相同的语言。只输出可直接粘贴使用的答案，不添加开场白或答案标签。保留必要的换行和代码格式。"
    public var timeoutSeconds: Double = 60
    public var maxInputBytes = 32 * 1024
    public var maxOutputTokens = 4096
    public var hotKeyCode: UInt32 = 38 // J, physical key
    public var hotKeyModifiers: UInt32 = 0x100 | 0x800 | 0x1000 // command + option + control
    public var localClipboardOnly = true
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case apiEndpoint, model, triggerPrefix, systemPrompt, timeoutSeconds, maxInputBytes, maxOutputTokens
        case hotKeyCode, hotKeyModifiers, localClipboardOnly
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiEndpoint = try c.decodeIfPresent(String.self, forKey: .apiEndpoint) ?? apiEndpoint
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        triggerPrefix = try c.decodeIfPresent(String.self, forKey: .triggerPrefix) ?? triggerPrefix
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? systemPrompt
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? timeoutSeconds
        maxInputBytes = try c.decodeIfPresent(Int.self, forKey: .maxInputBytes) ?? maxInputBytes
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? maxOutputTokens
        hotKeyCode = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyCode) ?? hotKeyCode
        hotKeyModifiers = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyModifiers) ?? hotKeyModifiers
        localClipboardOnly = try c.decodeIfPresent(Bool.self, forKey: .localClipboardOnly) ?? localClipboardOnly
        // Migrate the shipped 0.1 default (⌃⌥⌘J) to the 0.3 default (⌃C).
        // A user-chosen shortcut remains unchanged.
        if hotKeyCode == 38 && hotKeyModifiers == 6400 {
            hotKeyCode = 8
            hotKeyModifiers = 4096
        }
    }

    public func validate() throws {
        guard let url = URLComponents(string: apiEndpoint), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.url != nil, apiEndpoint.count <= 2048,
              !model.isEmpty, model.count <= 200,
              model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_/.:".contains($0)) }),
              !triggerPrefix.isEmpty, triggerPrefix.count <= 128,
              triggerPrefix.allSatisfy({ !$0.isNewline && !$0.isWhitespace }),
              !systemPrompt.isEmpty, systemPrompt.utf8.count <= 16_384,
              timeoutSeconds.isFinite, (1...300).contains(timeoutSeconds),
              (1...131_072).contains(maxInputBytes), (1...8192).contains(maxOutputTokens),
              hotKeyCode <= 127,
              hotKeyModifiers & ~UInt32(0x100 | 0x200 | 0x800 | 0x1000) == 0,
              (hotKeyModifiers & UInt32(0x100 | 0x200 | 0x800 | 0x1000)).nonzeroBitCount >= 1
        else { throw PipelineError.invalidConfiguration }
    }
}

public enum PipelineError: Error, Sendable, Equatable {
    case permission, noText, inputTooLarge, clipboardChanged, writeFailed
    case missingCredential, credentialUnavailable, invalidConfiguration
    case http(Int), invalidResponse, incompleteResponse, emptyResponse, responseTooLarge
    case network, timedOut, redirectRefused

    public var code: String {
        switch self {
        case .permission: "clipboard_permission_required"
        case .noText: "no_plain_text"
        case .inputTooLarge: "input_too_large"
        case .clipboardChanged: "clipboard_changed"
        case .writeFailed: "clipboard_write_failed"
        case .missingCredential: "key_missing"
        case .credentialUnavailable: "keychain_unavailable"
        case .invalidConfiguration: "invalid_configuration"
        case .http(let status): "http_\(status)"
        case .invalidResponse: "invalid_response"
        case .incompleteResponse: "incomplete_response"
        case .emptyResponse: "empty_response"
        case .responseTooLarge: "response_too_large"
        case .network: "network_error"
        case .timedOut: "timeout"
        case .redirectRefused: "redirect_refused"
        }
    }
}
