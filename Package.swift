// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notess",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Notess", targets: ["Notess"]),
        .library(name: "NotessCore", targets: ["NotessCore"]),
        .library(name: "NotessEditor", targets: ["NotessEditor"]),
    ],
    targets: [
        // Platform-independent domain logic (no AppKit/SwiftUI). Unit-tested.
        .target(name: "NotessCore"),
        // AppKit NSTextView (TextKit 2) editor wrapped for SwiftUI.
        .target(name: "NotessEditor"),
        // SwiftUI app shell: window, Vault selection, commands.
        .executableTarget(
            name: "Notess",
            dependencies: ["NotessCore", "NotessEditor"]
        ),
        .testTarget(
            name: "NotessCoreTests",
            dependencies: ["NotessCore"]
        ),
        .testTarget(
            name: "NotessEditorTests",
            dependencies: ["NotessEditor"]
        ),
    ]
)
