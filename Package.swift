// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SilentClipboard",
    platforms: [.macOS("15.4")],
    products: [.executable(name: "SilentClipboard", targets: ["SilentClipboardApp"])],
    targets: [
        .target(name: "ClipboardCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "SilentClipboardApp", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
    ]
)
