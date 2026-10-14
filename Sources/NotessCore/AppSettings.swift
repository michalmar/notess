import Foundation
import Observation

public struct EditorFont: Equatable, Sendable {
    public static let `default` = EditorFont(name: "System", size: 15)

    public var name: String
    public var size: Double

    public init(name: String, size: Double) {
        self.name = name
        self.size = size
    }
}

/// The app deliberately follows macOS's light/dark appearance rather than
/// maintaining a separate appearance preference.
public enum AppTheme: String, Sendable {
    case system
}

/// Observable, user-persistent settings that application features can consume.
@Observable
public final class AppSettings {
    private enum Key {
        static let editorFontName = "editorFontName"
        static let editorFontSize = "editorFontSize"
        static let copilotCLIPath = "copilotCLIPath"
    }

    public var editorFont: EditorFont {
        didSet { saveEditorFont() }
    }
    public var theme: AppTheme = .system
    /// A user-selected executable path. `nil` means use autodetection.
    public var copilotCLIPath: String? {
        didSet { defaults.set(copilotCLIPath, forKey: Key.copilotCLIPath) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fontName = defaults.string(forKey: Key.editorFontName) ?? EditorFont.default.name
        let storedSize = defaults.double(forKey: Key.editorFontSize)
        self.editorFont = EditorFont(
            name: fontName,
            size: storedSize == 0 ? EditorFont.default.size : storedSize
        )
        self.copilotCLIPath = defaults.string(forKey: Key.copilotCLIPath)
    }

    public func useAutodetectedCopilotCLI() {
        copilotCLIPath = nil
    }

    private func saveEditorFont() {
        defaults.set(editorFont.name, forKey: Key.editorFontName)
        defaults.set(editorFont.size, forKey: Key.editorFontSize)
    }
}
