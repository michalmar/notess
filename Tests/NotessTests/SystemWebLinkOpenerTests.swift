import AppKit
import Testing
@testable import Notess

@MainActor
@Suite("System web-link opening")
struct SystemWebLinkOpenerTests {
    @Test("macOS has a default application for HTTPS")
    func defaultBrowserIsAvailable() throws {
        let url = try #require(URL(string: "https://example.com"))
        #expect(NSWorkspace.shared.urlForApplication(toOpen: url) != nil)
    }
}

/// Explicit integration check: opens a fixed URL in the configured default
/// browser without including any note content.
@MainActor
@Suite(
    "Real default-browser handoff",
    .enabled(if: ProcessInfo.processInfo.environment["NOTESS_REAL_BROWSER"] == "1")
)
struct RealSystemWebLinkOpenerTests {
    @Test("NSWorkspace accepts the intended HTTPS URL")
    func opensFixedURL() throws {
        let url = try #require(URL(string: "https://example.com/notess-command-click-check"))
        #expect(SystemWebLinkOpener.open(url))
    }
}
