import Foundation
import NotessCore
import NotessEditor

extension AppModel {
    /// Follows a `[[target]]` or `[[target#Section]]` link clicked in the editor:
    /// opens the note in a tab (or selects its tab) and scrolls to the Section.
    /// A link that cannot be followed shows a message and changes nothing on disk.
    func openWikiLink(_ link: WikiLink) {
        guard let vault else { return }

        let document: NoteDocument
        let noteName: String
        if link.target.isEmpty {
            guard let current = tabSession.activeDocument else { return }
            document = current
            noteName = current.fileURL.deletingPathExtension().lastPathComponent
        } else {
            let resolver = WikiLinkResolver(relativePaths: vault.scanNotePaths())
            guard let relativePath = resolver.resolve(target: link.target) else {
                errorMessage = "Poznámka „\(link.target)“ ve Vaultu neexistuje."
                return
            }
            let url = vault.rootURL.appending(path: relativePath, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                errorMessage = "Poznámka „\(link.target)“ ve Vaultu neexistuje."
                return
            }
            guard let opened = openNote(at: url) else { return }
            document = opened
            noteName = link.target
        }

        guard let sectionName = link.section else {
            reveal = nil
            return
        }
        guard let section = NoteSection.find(sectionName, in: document.text) else {
            reveal = nil
            errorMessage = "Sekce „\(sectionName)“ v poznámce „\(noteName)“ neexistuje."
            return
        }
        reveal = EditorReveal(documentID: document.id, range: section.headingRange)
    }

    /// Opens the source of a backlink and reveals the Section that contains it.
    func openBacklink(_ backlink: Backlink) {
        guard let vault else { return }
        let url = vault.rootURL.appending(
            path: backlink.sourceRelativePath,
            directoryHint: .notDirectory
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Zdrojová poznámka už ve Vaultu neexistuje."
            rebuildBacklinks()
            return
        }
        guard let document = openExistingNote(relativePath: backlink.sourceRelativePath) else { return }

        guard let sectionTitle = backlink.sectionTitle,
              let occurrence = backlink.sectionTitleOccurrence,
              let section = NoteSection.find(sectionTitle, occurrence: occurrence, in: document.text) else {
            reveal = nil
            return
        }
        reveal = EditorReveal(documentID: document.id, range: section.headingRange)
    }
}
