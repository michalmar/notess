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
        static let textZoom = "textZoom"
    }

    /// The zoom multiplier limits; 1 is 100%, the configured editor font size.
    public static let textZoomRange: ClosedRange<Double> = 0.5...3.0
    /// What zoom in/out change the multiplier by: 10 percentage points.
    public static let textZoomStep = 0.1

    public var editorFont: EditorFont {
        didSet { saveEditorFont() }
    }
    /// Display-only zoom of the note editor's text, shared by all notes. It is
    /// a multiplier on `editorFont.size`, always finite and within `textZoomRange`.
    public var textZoom: Double {
        get { storedTextZoom }
        set {
            storedTextZoom = Self.sanitisedZoom(newValue)
            defaults.set(storedTextZoom, forKey: Key.textZoom)
        }
    }
    private var storedTextZoom: Double
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
        self.storedTextZoom = Self.sanitisedZoom(
            defaults.object(forKey: Key.textZoom) == nil ? 1 : defaults.double(forKey: Key.textZoom)
        )
    }

    /// The editor's body font size: the configured size scaled by the zoom.
    public var effectiveEditorFontSize: Double { editorFont.size * textZoom }

    /// The zoom as a whole percentage, for display.
    public var textZoomPercent: Int { Int((textZoom * 100).rounded()) }

    public var canZoomIn: Bool { textZoom < Self.textZoomRange.upperBound - 1e-9 }
    public var canZoomOut: Bool { textZoom > Self.textZoomRange.lowerBound + 1e-9 }

    public func zoomIn() { textZoom = Self.stepped(textZoom + Self.textZoomStep) }
    public func zoomOut() { textZoom = Self.stepped(textZoom - Self.textZoomStep) }
    public func resetTextZoom() { textZoom = 1 }

    /// Applies a pinch gesture's incremental magnification (0.1 is 10% bigger).
    public func pinchTextZoom(by magnification: Double) {
        guard magnification.isFinite else { return }
        textZoom = min(max(textZoom * max(0, 1 + magnification), Self.textZoomRange.lowerBound), Self.textZoomRange.upperBound)
    }

    /// Drops floating-point drift so repeated steps land exactly on 1.5, not 1.5000000000000002.
    private static func stepped(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    private static func sanitisedZoom(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return min(max(value, textZoomRange.lowerBound), textZoomRange.upperBound)
    }

    public func useAutodetectedCopilotCLI() {
        copilotCLIPath = nil
    }

    private func saveEditorFont() {
        defaults.set(editorFont.name, forKey: Key.editorFontName)
        defaults.set(editorFont.size, forKey: Key.editorFontSize)
    }
}
