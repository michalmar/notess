import Foundation
import Testing
@testable import NotessCore

@Suite("Brain Run: prompt and Copilot CLI command")
struct BrainRunPromptTests {
    @Test("the prompt carries the Agent instructions, the notes to process and the run rules")
    func promptContent() {
        let prompt = BrainRunPrompt.make(
            instructions: "# Instructions for the Agent\nUSER RULE 42",
            changes: BrainRunChanges(
                changed: ["Journal/2026/03/2026-03-14.md", "Projects/Plan.md"],
                deleted: ["Old idea.md"]
            )
        )

        #expect(prompt.contains("USER RULE 42"))
        #expect(prompt.contains("- `Journal/2026/03/2026-03-14.md` (cite as `[[2026-03-14#Section]]`)"))
        #expect(prompt.contains("- `Projects/Plan.md` (cite as `[[Plan#Section]]`)"))
        #expect(prompt.contains("- `Old idea.md` (its Citations look like `[[Old idea#…]]`)"))
        #expect(prompt.contains("Write only inside `_brain/`"))
        #expect(prompt.contains("Recompute"))
        #expect(prompt.contains("remove every fact whose Citation points to it"))
        #expect(prompt.contains("Citation"))
    }

    @Test("an empty list is stated explicitly")
    func emptyLists() {
        let prompt = BrainRunPrompt.make(
            instructions: "x",
            changes: BrainRunChanges(changed: [], deleted: ["Gone.md"])
        )

        #expect(prompt.contains("### Changed or new notes\n\nNone."))
    }

    @Test("Copilot CLI runs non-interactively in the Vault and may write only inside _brain/")
    func command() throws {
        let temp = try TemporaryVault()
        let resolved = try #require(realpath(temp.vault.rootURL.path, nil))
        defer { free(resolved) }
        let realRoot = String(cString: resolved)
        #expect(realRoot.hasPrefix("/private/"))
        let command = BrainRunCommand.copilot(
            executableURL: URL(filePath: "/opt/homebrew/bin/copilot"),
            vault: temp.vault,
            prompt: "PROMPT"
        )

        #expect(command.executableURL == URL(filePath: "/opt/homebrew/bin/copilot"))
        #expect(command.currentDirectoryURL == temp.vault.rootURL)
        let arguments = command.arguments
        #expect(arguments.starts(with: ["-p", "PROMPT"]))
        #expect(arguments.contains("--no-ask-user"))
        let allowed = pairs(after: "--allow-tool", in: arguments)
        let denied = pairs(after: "--deny-tool", in: arguments)
        // Copilot CLI matches write permissions against the real path (`/private/var/…`).
        #expect(allowed == ["write(\(realRoot)/_brain/**)"])
        #expect(denied.contains("shell"))
        #expect(denied.contains("write(\(realRoot)/_brain/AGENTS.md)"))
        #expect(!arguments.contains("--allow-all-tools"))
        #expect(!arguments.contains("--allow-all-paths"))
    }

    private func pairs(after flag: String, in arguments: [String]) -> [String] {
        zip(arguments, arguments.dropFirst()).filter { $0.0 == flag }.map(\.1)
    }
}

@Suite("Brain Run: finding Copilot CLI")
struct CopilotCLIResolutionTests {
    @Test("a path from Settings wins over autodetection")
    func configuredPath() {
        let locator = CopilotCLILocator(fileExists: { _ in true }, loginShellPath: { [] })

        #expect(locator.resolve(configuredPath: "/Users/me/copilot") == .found(URL(filePath: "/Users/me/copilot")))
    }

    @Test("a path from Settings that is not an executable is reported, not replaced by autodetection")
    func configuredPathMissing() {
        let locator = CopilotCLILocator(
            fileExists: { $0.path == "/opt/homebrew/bin/copilot" },
            loginShellPath: { [] }
        )

        #expect(locator.resolve(configuredPath: "/nope/copilot") == .configuredPathUnavailable("/nope/copilot"))
    }

    @Test("without a path in Settings, Copilot CLI is autodetected or reported missing")
    func autodetect() {
        let found = CopilotCLILocator(fileExists: { $0.path == "/opt/homebrew/bin/copilot" }, loginShellPath: { [] })
        let missing = CopilotCLILocator(fileExists: { _ in false }, loginShellPath: { [] })

        #expect(found.resolve(configuredPath: nil) == .found(URL(filePath: "/opt/homebrew/bin/copilot")))
        #expect(missing.resolve(configuredPath: nil) == .notFound)
    }
}
