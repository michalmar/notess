import Darwin
import Foundation

/// The prompt Copilot CLI gets for one Brain Run: the user's Agent instructions
/// from `_brain/AGENTS.md`, the notes to process and the rules of the run.
public enum BrainRunPrompt {
    public static func make(instructions: String, changes: BrainRunChanges) -> String {
        let changed = changes.changed.map {
            "- `\($0)` (cite as `[[\(citationName(of: $0))#Section]]`)"
        }
        let deleted = changes.deleted.map {
            "- `\($0)` (its Citations look like `[[\(citationName(of: $0))#…]]`)"
        }
        return """
        You are the Agent of Notess, running one Brain Run non-interactively. Your working \
        directory is the Vault. Follow the user's instructions from `\(Vault.brainInstructionsRelativePath)`, \
        reproduced between the markers below; the rules of this run come after them.

        ----- BEGIN \(Vault.brainInstructionsRelativePath) -----
        \(instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        ----- END \(Vault.brainInstructionsRelativePath) -----

        # This Brain Run

        Process exactly the notes listed here (paths are relative to the Vault). They changed since \
        the last successful Brain Run. Do not process other notes.

        ### Changed or new notes

        \(changed.isEmpty ? "None." : changed.joined(separator: "\n"))

        ### Deleted notes

        \(deleted.isEmpty ? "None." : deleted.joined(separator: "\n"))

        ## Rules of this run

        1. **Recompute, do not append.** Read each changed or new note whole, as it is on disk now, \
        and re-derive every fact it supports: add new facts, correct changed ones, and remove facts \
        citing that note which it no longer supports.
        2. **Deleted notes:** remove every fact whose Citation points to it. Search `\(NoteKind.brainFolder)/` \
        for those Citations.
        3. **Citations:** every fact ends with a Citation `[[Note name#Section heading]]` to the Section \
        (the `##` heading) it came from; the Note name is the file name without `.md`, so a Daily Entry \
        is cited as `[[YYYY-MM-DD#Section heading]]`. Never write a fact without a Citation.
        4. **Existing Entities first:** before creating a Brain Note, look in `\(NoteKind.brainFolder)/` for \
        a note or an `aliases:` entry of the same Entity and update that note instead.
        5. **Write only inside `\(NoteKind.brainFolder)/`.** Never create, change, move or delete anything \
        outside it, and do not change `\(Vault.brainInstructionsRelativePath)`. Notess blocks other \
        writes and reports any change outside `\(NoteKind.brainFolder)/` as an error. Shell commands are \
        not available; use the file tools.
        6. **Removing a Brain Note:** you cannot delete files. When a Brain Note has no facts left, \
        overwrite it with empty content; Notess deletes empty Brain Notes after the run.
        7. Do not ask questions. When done, reply with a short list of the Brain Notes you created, \
        changed or emptied.
        """
    }

    /// The name a Citation uses for a note: its file name without `.md`.
    static func citationName(of relativePath: String) -> String {
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }
}

/// One process launch: what to run, with which arguments, where.
public struct BrainRunCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL

    public init(executableURL: URL, arguments: [String], currentDirectoryURL: URL) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
    }

    /// Copilot CLI in prompt mode (`-p`), with the Vault as working directory.
    ///
    /// Non-interactive mode denies every tool that is not explicitly allowed,
    /// so the Agent may read the Vault but write only below `_brain/`
    /// (`write(<Vault>/_brain/**)`); `_brain/AGENTS.md`, shell commands and URL
    /// access are denied outright, and the temporary directory is off limits.
    /// Copilot CLI matches write permissions against real paths, so the Vault
    /// path is resolved first.
    public static func copilot(executableURL: URL, vault: Vault, prompt: String) -> BrainRunCommand {
        let root = realPath(of: vault.rootURL)
        let brain = "\(root)/\(NoteKind.brainFolder)"
        return BrainRunCommand(
            executableURL: executableURL,
            arguments: [
                "-p", prompt,
                "--allow-tool", "write(\(brain)/**)",
                "--deny-tool", "write(\(root)/\(Vault.brainInstructionsRelativePath))",
                "--deny-tool", "shell",
                "--deny-tool", "url",
                "--disallow-temp-dir",
                "--disable-builtin-mcps",
                "--no-custom-instructions",
                "--no-ask-user",
                "--no-color",
            ],
            currentDirectoryURL: vault.rootURL
        )
    }

    private static func realPath(of url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Where Copilot CLI is, from Settings or autodetection.
public enum CopilotCLIResolution: Equatable, Sendable {
    case found(URL)
    /// The path set in Settings is not an executable.
    case configuredPathUnavailable(String)
    /// Nothing set in Settings and autodetection found nothing.
    case notFound
}

extension CopilotCLILocator {
    /// A path set in Settings wins; it is never silently replaced by autodetection.
    public func resolve(configuredPath: String?) -> CopilotCLIResolution {
        if let configuredPath {
            let url = URL(filePath: configuredPath)
            return isExecutable(url) ? .found(url) : .configuredPathUnavailable(configuredPath)
        }
        return detect().map(CopilotCLIResolution.found) ?? .notFound
    }
}
