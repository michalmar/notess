# Native Swift app (SwiftUI + AppKit/TextKit 2), macOS 15+

Instant launch, instant close and zero-lag typing are the top product priorities, so the app is built natively in Swift: SwiftUI for window chrome, sidebar and tabs, and an AppKit `NSTextView` on TextKit 2 for the Markdown editor. Cross-platform shells (Tauri, Electron) were rejected because of startup cost and non-native text editing. The minimum target is macOS 15 to avoid compatibility workarounds.
