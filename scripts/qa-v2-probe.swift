// Test harness only. Never bundled in the application.
// Keeps the pre-test clipboard in memory; emits metadata, never clipboard contents.
import AppKit
import CoreGraphics
import Carbon

let originalInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()

let board = NSPasteboard.general
if #available(macOS 15.4, *) {
    guard board.accessBehavior == .alwaysAllow else { fatalError("QA clipboard permission unavailable") }
} else { fatalError("QA requires macOS 15.4") }
let original: [[NSPasteboard.PasteboardType: Data]] = (board.pasteboardItems ?? []).map { item in
    Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
}
var lastOwnedVersion = board.changeCount
func emit(_ result: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
}
func windowMetadata() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).map {
        ["pid": $0[kCGWindowOwnerPID as String] ?? 0,
         "owner": $0[kCGWindowOwnerName as String] ?? "",
         "number": $0[kCGWindowNumber as String] ?? 0,
         "layer": $0[kCGWindowLayer as String] ?? 0,
         "bounds": $0[kCGWindowBounds as String] ?? [:]]
    }
}
func sendKey(_ code: CGKeyCode, flags: CGEventFlags) {
    guard CGPreflightPostEventAccess() else { return }
    let source = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }
}
emit(["ready": true, "postingAllowed": CGPreflightPostEventAccess()])
while let line = readLine() {
    switch line {
    case "seed":
        board.prepareForNewContents(with: [.currentHostOnly])
        board.setString("$c 只输出：春夏秋冬天地人。不加标点或其他文字。", forType: .string)
        lastOwnedVersion = board.changeCount; emit(["seeded": true])
    case "ime-abc":
        let matches = TISCreateInputSourceList([kTISPropertyInputSourceID: "com.apple.keylayout.ABC"] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
        emit(["selected": matches.first.map { TISSelectInputSource($0) == noErr } ?? false])
    case "ime-wetype":
        let matches = TISCreateInputSourceList([kTISPropertyInputSourceID: "com.tencent.inputmethod.wetype.pinyin"] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
        emit(["selected": matches.first.map { TISSelectInputSource($0) == noErr } ?? false])
    case "type-nihao":
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" else {
            emit(["typed": false, "reason": "test_browser_not_frontmost"]); continue
        }
        for code: CGKeyCode in [45, 34, 4, 0, 31] { sendKey(code, flags: []); Thread.sleep(forTimeInterval: 0.1) }
        emit(["typed": true])
    case "hotkey": sendKey(38, flags: [.maskControl, .maskAlternate, .maskCommand]); emit(["posted": true])
    case "copy": sendKey(8, flags: .maskCommand); emit(["copyPosted": true])
    case "paste": sendKey(9, flags: .maskControl); emit(["pastePosted": true])
    case "status":
        emit(["version": board.changeCount,
              "foregroundPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
              "foreground": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
              "windows": windowMetadata()])
    case "own": lastOwnedVersion = board.changeCount; emit(["owned": true])
    case "check":
        let value = board.string(forType: .string)
        emit(["answerMatches": value == "CLIPBOARD_TEST_OK", "protectedCopyMatches": value == "NEW_COPY_MUST_SURVIVE",
              "promptMatches": value == "$c 只输出：春夏秋冬天地人。不加标点或其他文字。", "version": board.changeCount])
    case "new-copy":
        board.clearContents(); board.setString("NEW_COPY_MUST_SURVIVE", forType: .string)
        lastOwnedVersion = board.changeCount; emit(["newCopy": true])
    case "restore":
        let inputRestored = TISSelectInputSource(originalInputSource) == noErr
        if board.changeCount == lastOwnedVersion {
            let items = original.map { saved in
                let item = NSPasteboardItem()
                for (type, data) in saved { item.setData(data, forType: type) }
                return item
            }
            board.prepareForNewContents(with: [.currentHostOnly]); board.writeObjects(items)
            emit(["restored": true, "inputSourceRestored": inputRestored])
        } else { emit(["restored": false, "reason": "clipboard_changed_since_test_owned_it"]) }
        exit(0)
    default: emit(["unknownCommand": true])
    }
}
