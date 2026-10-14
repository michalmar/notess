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
    var isQuickOpenPresented = false
    /// Vault-relative folder chosen in the Notes section ("" is the Vault root); target for new Free Notes.
    var selectedFolder = ""
    var errorMessage: String?
    /// Section to scroll the editor to after following a wiki-link.
    var reveal: EditorReveal?
    let settings: AppSettings

    @ObservationIgnored private let vaultLocationStore: VaultLocationStore
    @ObservationIgnored private let tabRestorationStore: TabRestorationStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var watcher: VaultWatcher?

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

    func presentQuickOpen() {
        guard vault != nil else { return }
        isQuickOpenPresented = true
    }

    /// Brings the sidebar and open tabs in line with the Vault on disk after
    /// outside changes (git, other editors, the Agent).
    func reconcileWithDisk() {
        refreshTree()
        tabSession.reconcileWithDisk()
    }

    /// Where every batch of outside Vault changes lands; features that react to
    /// new files (e.g. Brain Notes after a Brain Run) hook in here.
    func handleVaultChange(_ change: VaultChange) {
        reconcileWithDisk()
    }

    /// "Načíst": replaces a tab's unsaved text with the file on disk.
    func reloadFromDisk(documentID: NoteDocument.ID) {
        guard let document = tabSession.documents.first(where: { $0.id == documentID }) else { return }
        do {
            try document.reloadFromDisk()
        } catch {
            errorMessage = "Soubor se nepodařilo načíst: \(error.localizedDescription)"
        }
    }

    /// Returns `false` if saving failed; the error is then in `errorMessage`, except when the
    /// file changed outside Notess: then the tab is selected and its bar asks what to do.
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
        } catch is NoteDocument.SaveError {
            // The file changed or vanished outside Notess: the tab's bar asks what to do.
            tabSession.select(documentID: document.id)
            persistTabs()
            return false
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
        isQuickOpenPresented = false
        watch(vault)
        do {
            try vault.ensureBrainInstructions()
        } catch {
            errorMessage = "Výchozí _brain/AGENTS.md se nepodařilo vytvořit: \(error.localizedDescription)"
        }
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

    private func watch(_ vault: Vault) {
        watcher?.stop()
        let watcher = VaultWatcher(rootURL: vault.rootURL, queue: .main) { [weak self] change in
            MainActor.assumeIsolated { self?.handleVaultChange(change) }
        }
        // Without FSEvents, outside changes are still picked up when the app becomes active.
        try? watcher.start()
        self.watcher = watcher
    }

    @discardableResult
    private func openNote(
        at fileURL: URL,
        newFileContent: String,
        errorPrefix: String
    ) -> NoteDocument? {
        guard vault?.contains(fileURL) ?? true else {
            errorMessage = "\(errorPrefix): soubor leží mimo Vault."
            return nil
        }
        do {
            let document = try tabSession.openNote(
                at: fileURL,
                newFileContent: newFileContent,
                isReadOnly: isBrainNote(fileURL)
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

    /// Brain Notes are read-only whichever way they are opened (sidebar, wiki-link, tab restoration).
    private func isBrainNote(_ fileURL: URL) -> Bool {
        guard let vault else { return false }
        let root = vault.rootURL.resolvingSymlinksInPath().path + "/"
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { return false }
        return NoteKind.classify(relativePath: String(path.dropFirst(root.count))) == .brainNote
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
