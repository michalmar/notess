import Foundation
import Testing
@testable import NotessCore

@Suite("Copilot CLI autodetection")
struct CopilotCLILocatorTests {
    @Test("finds Copilot CLI in a standard installation location")
    func findsStandardLocation() {
        let locator = CopilotCLILocator(
            fileExists: { $0.path == "/opt/homebrew/bin/copilot" },
            loginShellPath: { [] }
        )

        #expect(locator.detect() == URL(filePath: "/opt/homebrew/bin/copilot"))
    }

    @Test("uses the login shell PATH when standard locations are unavailable")
    func findsLoginShellPath() {
        let locator = CopilotCLILocator(
            fileExists: { $0.path == "/Users/me/.local/bin/copilot" },
            loginShellPath: { [URL(filePath: "/Users/me/.local/bin")] }
        )

        #expect(locator.detect() == URL(filePath: "/Users/me/.local/bin/copilot"))
    }

    @Test("prefers standard installation locations over the login shell PATH")
    func standardLocationWins() {
        let locator = CopilotCLILocator(
            fileExists: {
                ["/opt/homebrew/bin/copilot", "/Users/me/bin/copilot"].contains($0.path)
            },
            loginShellPath: { [URL(filePath: "/Users/me/bin")] }
        )

        #expect(locator.detect() == URL(filePath: "/opt/homebrew/bin/copilot"))
    }

    @Test("returns nil when Copilot CLI is unavailable")
    func noCopilotCLI() {
        let locator = CopilotCLILocator(
            fileExists: { _ in false },
            loginShellPath: { [] }
        )

        #expect(locator.detect() == nil)
    }
}
