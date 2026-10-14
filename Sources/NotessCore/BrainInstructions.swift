import Foundation

/// The default content of `_brain/AGENTS.md` and the parsing of its Entity type list.
public enum BrainInstructions {
    /// Heading of the section that lists the Entity types.
    public static let entityTypesHeading = "Entity types"

    /// Entity types are the bullets of the `## Entity types` section, each starting with the
    /// folder in backticks (`` - `people/` — a person ``). Folders are relative to `_brain/`.
    public static func entityTypes(in text: String) -> [EntityType] {
        var types: [EntityType] = []
        var inSection = false
        var inCodeFence = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCodeFence.toggle()
                continue
            }
            if inCodeFence { continue }
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                let level = line.prefix(while: { $0 == "#" }).count
                if inSection && level <= 2 { break }
                if level == 2 && heading.caseInsensitiveCompare(entityTypesHeading) == .orderedSame {
                    inSection = true
                }
                continue
            }
            guard inSection, let folder = folder(fromBullet: line),
                  !types.contains(where: { $0.folder == folder }) else { continue }
            types.append(EntityType(folder: folder))
        }
        return types
    }

    private static func folder(fromBullet line: String) -> String? {
        guard let first = line.first, "-*+".contains(first) else { return nil }
        let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") else { return nil }
        let name = rest[rest.index(after: rest.startIndex)..<close]
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.hasPrefix("."), name != NoteKind.attachmentsFolder else { return nil }
        return name
    }

    public static let defaultContent = """
    # Instructions for the Agent

    You are the Agent of Notess. You maintain a "second brain": Brain Notes that distil facts from
    the user's notes. You run non-interactively with the Vault as your working directory.
    This file is yours to follow and the user's to edit.

    ## Rules

    1. **Write only inside `_brain/`.** Never create, change, move or delete anything outside it.
       In particular never touch Daily Entries (`Journal/`) or Free Notes. Do not modify this file.
    2. **Every fact needs a Citation.** Write each fact as one bullet ending with a link to the
       Section it came from: `[[YYYY-MM-DD#Section heading]]` for a Daily Entry, or
       `[[Note title#Section heading]]` for a Free Note. A fact without a Citation must not exist.
    3. **One Entity, one Brain Note.** Each Entity gets exactly one note, named after the Entity
       (`_brain/<type folder>/<Entity name>.md`). Never create a second note for the same Entity.
    4. **Aliases.** Keep nicknames and other names of the Entity in the front-matter `aliases:` list
       of its Brain Note, and use them to recognise the Entity in the notes.
    5. **When unsure, do not merge.** If you cannot tell whether two names mean the same Entity,
       create a separate Entity and add the line `Possibly the same as [[Other Entity]]`
       (Czech notes: `možná totožné s [[Other Entity]]`) to both notes.
    6. **Recompute, do not append.** For every file you are asked to process, read the whole current
       file and re-derive the facts it supports. Update or remove facts that no longer match it.
    7. **Delete facts without a source.** If a file was deleted, or a Section no longer says what a
       fact claims, remove that fact. Remove a Brain Note once it has no facts left.
    8. **Write facts, not copies.** Be concise and neutral; state only what the notes say.
       Write in the language of the source notes.

    ## Entity types

    Each type is a folder inside `_brain/`. Add or remove lines to change what is tracked;
    Notess groups Brain Notes in its sidebar by this list.

    - `people/` — a person
    - `companies/` — a company or organisation
    - `projects/` — a project or initiative
    - `places/` — a place

    ## Brain Note format

    ```markdown
    ---
    aliases: [Nickname, Other name]
    ---
    # Entity name

    - A fact about the Entity. [[2026-03-14#Meeting with Anna]]
    - Another fact. [[2026-03-20#Ideas]] [[Project plan#Goals]]
    ```
    """ + "\n"
}
