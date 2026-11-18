import AppKit
import Carbon

@MainActor enum TextOutput {
    static var allowed: Bool { CGPreflightPostEventAccess() }

    /// Explicit user output only. No AX, selection, browser, or window-content reads.
    /// Unicode events avoid invoking a menu action or changing the pasteboard.
    static func send(_ text: String) -> Bool {
        guard allowed, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(), !app.isTerminated,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        let units = Array(text.utf16)
        down.flags = []; up.flags = []
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        }
        // Do not activate the destination. A focus change cannot redirect this pair to another process.
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        return true
    }
}
