import AppKit

public struct ClipboardSnapshot: Sendable {
    public let text: String
    public let version: Int
    public init(text: String, version: Int) { self.text = text; self.version = version }
}

@MainActor public protocol ClipboardAccess: AnyObject {
    var accessAllowed: Bool { get }
    var version: Int { get }
    func readPlainText() -> String?
    func writeAnswer(_ text: String, localOnly: Bool) -> Bool
}

@MainActor public enum ClipboardTransaction {
    public static func capture(_ clipboard: any ClipboardAccess, maxBytes: Int) throws -> ClipboardSnapshot {
        guard clipboard.accessAllowed else { throw PipelineError.permission }
        let before = clipboard.version
        guard let text = clipboard.readPlainText() else { throw PipelineError.noText }
        guard before == clipboard.version else { throw PipelineError.clipboardChanged }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PipelineError.noText }
        guard text.utf8.count <= maxBytes else { throw PipelineError.inputTooLarge }
        return ClipboardSnapshot(text: text, version: before)
    }

    public static func commit(_ text: String, expectedVersion: Int,
                              to clipboard: any ClipboardAccess, localOnly: Bool) throws {
        guard clipboard.accessAllowed else { throw PipelineError.permission }
        guard clipboard.version == expectedVersion else { throw PipelineError.clipboardChanged }
        guard clipboard.writeAnswer(text, localOnly: localOnly) else { throw PipelineError.writeFailed }
    }
}

@MainActor public final class SystemClipboard: ClipboardAccess {
    private let pasteboard: NSPasteboard
    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    public var accessAllowed: Bool { pasteboard.accessBehavior == .alwaysAllow }
    public var accessName: String {
        switch pasteboard.accessBehavior {
        case .alwaysAllow: "allowed"
        case .alwaysDeny: "denied"
        case .ask: "ask"
        case .default: "not_configured"
        @unknown default: "unknown"
        }
    }
    public var version: Int { pasteboard.changeCount }
    public func readPlainText() -> String? {
        guard accessAllowed else { return nil }
        // No file/URL expansion, rich text conversion, or other-app API calls.
        guard pasteboard.types?.contains(.string) == true else { return nil }
        return pasteboard.string(forType: .string)
    }
    public func writeAnswer(_ text: String, localOnly: Bool) -> Bool {
        // Stage the complete representation before taking pasteboard ownership.
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        pasteboard.prepareForNewContents(with: localOnly ? [.currentHostOnly] : [])
        return pasteboard.writeObjects([item])
    }
    /// Called exclusively by the explicit, interactive setup command.
    /// Never called on launch, on a hotkey, or after runtime permission failure.
    public func authorizeInteractively() {
        if !accessAllowed { _ = pasteboard.string(forType: .string) }
    }
}
