// External QA only. This file is not linked into the application.
import AppKit
import CoreGraphics

func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}
func foreground() -> pid_t { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
let originalPID = foreground()
let originalBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
let baseline = windows()
let baselineIDs = Set(baseline.compactMap { $0[kCGWindowNumber as String] as? Int })
let baselineOwners = Dictionary(uniqueKeysWithValues: baseline.compactMap { item -> (Int, String)? in
    guard let id = item[kCGWindowNumber as String] as? Int else { return nil }
    return (id, item[kCGWindowOwnerName as String] as? String ?? "unknown")
})
var newWindowOwners = Set<String>()
var removedWindowOwners = Set<String>()
var changedForeground = Set<Int32>()
var ownWindowObserved = false
var spaceChanges = 0
let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in spaceChanges += 1 }
guard CGPreflightPostEventAccess() else { fatalError("Test event posting unavailable") }
let source = CGEventSource(stateID: .privateState)
func post(_ down: Bool) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: 38, keyDown: down)
    event?.flags = [.maskCommand, .maskControl, .maskAlternate]
    event?.post(tap: .cghidEventTap)
}
post(true)
let releaseAt = Date().addingTimeInterval(0.15)
var released = false
let until = Date().addingTimeInterval(4)
var samples = 0
while Date() < until {
    if !released && Date() >= releaseAt { post(false); released = true }
    let current = foreground()
    if current != originalPID { changedForeground.insert(current) }
    let currentWindows = windows()
    let currentIDs = Set(currentWindows.compactMap { $0[kCGWindowNumber as String] as? Int })
    for id in baselineIDs.subtracting(currentIDs) { removedWindowOwners.insert(baselineOwners[id] ?? "unknown") }
    for window in currentWindows {
        let owner = window[kCGWindowOwnerName as String] as? String ?? "unknown"
        if owner == "SilentClipboard" { ownWindowObserved = true }
        if let id = window[kCGWindowNumber as String] as? Int, !baselineIDs.contains(id) { newWindowOwners.insert(owner) }
    }
    samples += 1
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
NSWorkspace.shared.notificationCenter.removeObserver(observer)
let result: [String: Any] = ["initialForeground": originalBundle, "focusChanged": !changedForeground.isEmpty,
    "newWindowOwners": newWindowOwners.sorted(), "appWindowObserved": ownWindowObserved,
    "removedWindowOwners": removedWindowOwners.sorted(), "baselineWindowOwners": Set(baselineOwners.values).sorted(),
    "spaceChanges": spaceChanges, "samples": samples]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
print(String(decoding: data, as: UTF8.self))
