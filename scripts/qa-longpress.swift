// External QA only. Sends repeats to the application's exclusively registered hotkey.
import CoreGraphics
import Foundation
guard CGPreflightPostEventAccess() else { fatalError("QA event posting unavailable") }
let source = CGEventSource(stateID: .privateState)
for index in 0..<8 {
    let event = CGEvent(keyboardEventSource: source, virtualKey: 38, keyDown: true)
    event?.flags = [.maskCommand, .maskControl, .maskAlternate]
    event?.setIntegerValueField(.keyboardEventAutorepeat, value: index == 0 ? 0 : 1)
    event?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.2)
}
let release = CGEvent(keyboardEventSource: source, virtualKey: 38, keyDown: false)
release?.flags = [.maskCommand, .maskControl, .maskAlternate]
release?.post(tap: .cghidEventTap)
print("Posted one held shortcut with seven repeats and a release.")
