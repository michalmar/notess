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
}
