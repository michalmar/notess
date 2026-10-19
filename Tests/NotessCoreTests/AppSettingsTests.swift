import Foundation
import Testing
@testable import NotessCore

@Suite("Application settings")
struct AppSettingsTests {
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "NotessSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("editor font settings persist across launches")
    func editorFontPersists() throws {
        let defaults = try isolatedDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.editorFont = EditorFont(name: "Menlo", size: 18)

        #expect(AppSettings(defaults: defaults).editorFont == EditorFont(name: "Menlo", size: 18))
    }

    @Test("a manual Copilot CLI path overrides autodetection")
    func manualCopilotCLIPathOverridesDetection() throws {
        let settings = AppSettings(defaults: try isolatedDefaults())

        settings.copilotCLIPath = "/custom/bin/copilot"

        #expect(settings.copilotCLIPath == "/custom/bin/copilot")
    }

    @Test("text zoom starts at 100% and is independent of the editor font")
    func textZoomDefaultsToActualSize() throws {
        let settings = AppSettings(defaults: try isolatedDefaults())

        #expect(settings.textZoom == 1)
        #expect(settings.effectiveEditorFontSize == EditorFont.default.size)

        settings.editorFont = EditorFont(name: "Menlo", size: 20)
        settings.textZoom = 1.5

        #expect(settings.editorFont == EditorFont(name: "Menlo", size: 20))
        #expect(settings.effectiveEditorFontSize == 30)
    }

    @Test("a base font change keeps the zoom multiplier")
    func baseFontChangeKeepsZoom() throws {
        let settings = AppSettings(defaults: try isolatedDefaults())
        settings.textZoom = 1.5

        settings.editorFont.size = 12

        #expect(settings.textZoom == 1.5)
        #expect(settings.effectiveEditorFontSize == 18)
    }

    @Test("zoom persists across settings instances without touching the font")
    func textZoomPersists() throws {
        let defaults = try isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.editorFont = EditorFont(name: "Menlo", size: 18)
        settings.textZoom = 1.234

        let reopened = AppSettings(defaults: defaults)

        #expect(reopened.textZoom == 1.234)
        #expect(reopened.editorFont == EditorFont(name: "Menlo", size: 18))
    }

    @Test("buttons and shortcuts move zoom by ten percentage points")
    func zoomStepsByTenPoints() throws {
        let settings = AppSettings(defaults: try isolatedDefaults())

        for _ in 0..<5 { settings.zoomIn() }
        #expect(settings.textZoomPercent == 150)
        #expect(settings.effectiveEditorFontSize == 22.5)

        settings.zoomOut()
        #expect(settings.textZoomPercent == 140)

        settings.textZoom = 1.234
        settings.zoomIn()
        #expect(abs(settings.textZoom - 1.334) < 1e-9)
        settings.zoomOut()
        settings.zoomOut()
        #expect(abs(settings.textZoom - 1.134) < 1e-9)
    }

    @Test("reset returns to 100%")
    func resetTextZoom() throws {
        let settings = AppSettings(defaults: try isolatedDefaults())
        settings.textZoom = 2.2

        settings.resetTextZoom()

        #expect(settings.textZoom == 1)
    }

    @Test("zoom stops at 50% and 300% and the matching actions become unavailable")
    func zoomLimits() throws {
        let settings = AppSettings(defaults: try isolatedDefaults())

        for _ in 0..<40 { settings.zoomIn() }
        #expect(settings.textZoom == 3)
        #expect(!settings.canZoomIn)
        #expect(settings.canZoomOut)
        settings.zoomIn()
        #expect(settings.textZoom == 3)

        for _ in 0..<40 { settings.zoomOut() }
        #expect(settings.textZoom == 0.5)
        #expect(!settings.canZoomOut)
        #expect(settings.canZoomIn)
        settings.zoomOut()
        #expect(settings.textZoom == 0.5)

        settings.textZoom = 2.95
        settings.zoomIn()
        #expect(settings.textZoom == 3)
        settings.textZoom = 0.55
        settings.zoomOut()
        #expect(settings.textZoom == 0.5)
    }

    @Test("assigned zoom is clamped and never non-finite")
    func assignedZoomIsSanitised() throws {
        let settings = AppSettings(defaults: try isolatedDefaults())

        settings.textZoom = 10
        #expect(settings.textZoom == 3)
        settings.textZoom = 0.01
        #expect(settings.textZoom == 0.5)
        settings.textZoom = .nan
        #expect(settings.textZoom == 1)
        settings.textZoom = .infinity
        #expect(settings.textZoom == 1)
    }

    @Test("pinch scales zoom continuously within the limits")
    func pinchZoom() throws {
        let settings = AppSettings(defaults: try isolatedDefaults())

        settings.pinchTextZoom(by: 0.25)
        #expect(settings.textZoom == 1.25)
        settings.pinchTextZoom(by: -0.2)
        #expect(abs(settings.textZoom - 1.0) < 1e-9)
        settings.pinchTextZoom(by: 100)
        #expect(settings.textZoom == 3)
        settings.pinchTextZoom(by: -2)
        #expect(settings.textZoom == 0.5)
        settings.pinchTextZoom(by: .nan)
        #expect(settings.textZoom == 0.5)
    }

    @Test("invalid stored zoom is never restored")
    func invalidStoredZoom() throws {
        for (stored, expected): (Double, Double) in [(.nan, 1), (.infinity, 1), (0, 1), (-2, 1), (9, 3), (0.1, 0.5)] {
            let defaults = try isolatedDefaults()
            defaults.set(stored, forKey: "textZoom")
            #expect(AppSettings(defaults: defaults).textZoom == expected)
        }
    }
}
