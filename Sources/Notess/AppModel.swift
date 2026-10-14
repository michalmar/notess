import Foundation
import NotessCore
import NotessEditor
import Observation

/// App-wide state: which Vault is open and which note tabs are open.
@MainActor
@Observable
final class AppModel {
    private(set) var vault: Vault?
    private(set) var tabSession = TabSession()
    private(set) var tree: VaultTree = .empty
    /// Vault-relative folder chosen in the Notes section ("" is the Vault root); target for new Free Notes.
    var selectedFolder = ""
    var errorMessage: String?
    /// Section to scroll the editor to after following a wiki-link.
    var reveal: EditorReveal?
    let settings: AppSettings

    @ObservationIgnored private let vaultLocationStore: VaultLocationStore
    @ObservationIgnored private let tabRestorationStore: TabRestorationStore
    @ObservationIgnored private let now: () -> Date

    init(
        vaultLocationStore: VaultLocationStore = VaultLocationStore(),
        tabRestorationStore: TabRestorationStore = TabRestorationStore(),
        settings: AppSettings = AppSettings(),
        now: @escaping () -> Date = Date.init
    ) {
        self.vaultLocationStore = vaultLocationStore
        self.tabRestorationStore = tabRestorationStore
        self.settings = settings
        self.now = now
        if let saved = vaultLocationStore.savedVault() {
            open(saved)
        }
    }

    var document: NoteDocument? {
        tabSession.activeDocument
    }

    var hasUnsavedChanges: Bool {
        tabSession.hasUnsavedChanges
    }

    func chooseVault(at url: URL) {
        let vault = Vault(rootURL: url)
        vaultLocationStore.remember(vault)
        open(vault)
    }

    func openToday() {
        openDailyEntry(DailyEntry(date: now()))
    }

    /// Cmd+N: a new Free Note in the folder selected in the Notes section.
    func newFreeNote() {
        guard let vault else { return }
        do {
            let document = try vault.newFreeNote(
                inFolder: selectedFolder,
                on: Day(date: now())
            )
            tabSession.open(document)
            persistTabs()
        } catch {
            errorMessage = "Poznámku se nepodařilo vytvořit: \(error.localizedDescription)"
        }
    }

    func openDailyEntry(_ entry: DailyEntry) {
        guard let vault else { return }
        openNote(
            at: vault.url(for: entry),
            newFileContent: entry.initialContent,
            errorPrefix: "Záznam se nepodařilo otevřít"
        )
    }

    /// Opens a Vault file in a tab, or selects its existing tab.
    @discardableResult
    func openNote(at fileURL: URL, newFileContent: String = "") -> NoteDocument? {
        openNote(
            at: fileURL,
            newFileContent: newFileContent,
            errorPrefix: "Poznámku se nepodařilo otevřít"
        )
    }

    /// Single entry point for opening a file from the sidebar.
    func openNote(relativePath: String) {
        guard let vault else { return }
        do {
            let document = try vault.openNote(relativePath: relativePath)
            tabSession.open(document)
            persistTabs()
        } catch {
            errorMessage = "Poznámku se nepodařilo otevřít: \(error.localizedDescription)"
        }
    }

    func selectTab(documentID: NoteDocument.ID) {
        reveal = nil
        tabSession.select(documentID: documentID)
        persistTabs()
    }

    func closeTab(documentID: NoteDocument.ID) {
        reveal = nil
        tabSession.closeTab(documentID: documentID)
        persistTabs()
    }

    func refreshTree() {
        tree = vault?.scanTree() ?? .empty
    }

    /// Returns `false` if saving failed; the error is then in `errorMessage`.
    @discardableResult
    func save(documentID: NoteDocument.ID? = nil) -> Bool {
        let document = documentID.flatMap { id in
            tabSession.documents.first(where: { $0.id == id })
        } ?? tabSession.activeDocument
        guard let document else { return true }
        do {
            try document.save()
            refreshTree()
            persistTabs()
            return true
        } catch {
            errorMessage = "Uložení se nezdařilo: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveAll() -> Bool {
        for document in tabSession.unsavedDocuments {
            guard save(documentID: document.id) else { return false }
        }
        return true
    }

    private func open(_ vault: Vault) {
        self.vault = vault
        tabSession = TabSession()
        selectedFolder = ""
        refreshTree()
        do {
            if let state = try tabRestorationStore.savedState(for: vault) {
                restoreTabs(from: state, in: vault)
            } else {
                openToday()
            }
        } catch {
            errorMessage = "Obnova otevřených tabů se nezdařila: \(error.localizedDescription)"
            openToday()
        }
    }

    @discardableResult
    private func openNote(
        at fileURL: URL,
        newFileContent: String,
        errorPrefix: String
    ) -> NoteDocument? {
        do {
            let document = try tabSession.openNote(
                at: fileURL,
                newFileContent: newFileContent
            )
            persistTabs()
            return document
        } catch {
            errorMessage = "\(errorPrefix): \(error.localizedDescription)"
            return nil
        }
    }

    private func restoreTabs(from state: TabRestorationState, in vault: Vault) {
        let today = DailyEntry(date: now())
        for relativePath in state.relativePaths {
            guard let url = restorationURL(for: relativePath, in: vault) else {
                errorMessage = "Některé uložené taby měly neplatnou cestu a nebyly obnoveny."
                continue
            }
            let isToday = relativePath == today.relativePath
            guard isToday || FileManager.default.fileExists(atPath: url.path) else { continue }
            _ = openNote(
                at: url,
                newFileContent: isToday ? today.initialContent : "",
                errorPrefix: "Tab se nepodařilo obnovit"
            )
        }

        guard let activePath = state.activeRelativePath,
              let activeURL = restorationURL(for: activePath, in: vault),
              let active = tabSession.documents.first(where: {
                  TabSession.refersToSameFile($0.fileURL, activeURL)
              }) else { return }
        tabSession.select(documentID: active.id)
        persistTabs()
    }

    private func restorationURL(for relativePath: String, in vault: Vault) -> URL? {
        let components = NSString(string: relativePath).pathComponents
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              !components.contains(".."),
              !components.contains(".") else { return nil }
        return vault.rootURL.appending(path: relativePath, directoryHint: .notDirectory)
    }

    private func persistTabs() {
        guard let vault else { return }
        do {
            try tabRestorationStore.remember(
                tabSession.restorationState(relativeTo: vault.rootURL),
                for: vault
            )
        } catch {
            errorMessage = "Stav otevřených tabů se nepodařilo uložit: \(error.localizedDescription)"
        }
    }
}
