import Foundation
import NotessCore
import NotessEditor
import Observation

/// The two ways to browse the Vault in the sidebar.
enum SidebarMode: Hashable {
    /// The day-based workflow: Journal, Notes and Brain, with the note editor.
    case journal
    /// Tags of saved Daily Entries, with the selected Tag's timeline.
    case tags
}

/// App-wide state: which Vault is open and which note tabs are open.
@MainActor
@Observable
final class AppModel {
    private(set) var vault: Vault?
    private(set) var tabSession = TabSession()
    private(set) var tree: VaultTree = .empty
    var isQuickOpenPresented = false
    /// The open Cmd+Shift+F global search, or nil while it is closed.
    var globalSearch: GlobalSearch?
    var isSearchPresented: Bool {
        get { globalSearch != nil }
        set {
            if newValue {
                presentSearch()
            } else {
                globalSearch?.cancel()
                globalSearch = nil
            }
        }
    }
    /// Whether the main note window is the key window (not Settings or a dialog).
    var isNoteWindowKey = false
    /// The search index is catching up with the Vault or being rebuilt.
    var isIndexing = false
    /// Why the search index may be missing saved notes, until a full catch-up succeeds.
    var searchIndexFailure: String?
    /// Bumped whenever the search index has changed, so open results refresh.
    var searchIndexRevision = 0 {
        didSet { refreshTagTimeline() }
    }
    /// What the sidebar and the detail show: the day-based workflow or the Tag Timeline.
    var sidebarMode: SidebarMode = .journal {
        didSet {
            guard sidebarMode != oldValue else { return }
            refreshTagTimeline()
        }
    }
    /// The Tags of saved Daily Entries and the selected Tag's timeline (Tags mode).
    let tagTimeline = TagTimelineBrowser()
    /// The open Vault's Tag Groups; change them through `AppModel+TagGroups`.
    var tagGroups = TagGroups()
    /// Why the open Vault's Tag Groups could not be read; they are then not
    /// changed, so the unreadable settings are not overwritten.
    var tagGroupsLoadFailure: String?
    /// Vault-relative folder chosen in the Notes section ("" is the Vault root); target for new Free Notes.
    var selectedFolder = ""
    var errorMessage: String?
    var noteDeletionConfirmation: NoteDeletionConfirmation?
    /// Section to scroll the editor to after following a wiki-link.
    var reveal: EditorReveal?
    let imagePreview = ImagePreviewPresentation()
    private(set) var backlinks: [Backlink] = []
    let settings: AppSettings
    /// Where the Brain Run stands, shown in the toolbar.
    var brainRunPhase: BrainRunPhase = .idle
    /// When the open Vault's last successful Brain Run finished.
    var lastSuccessfulBrainRun: Date?
    let brainRunLog = BrainRunLog()
    var isBrainRunLogPresented = false

    @ObservationIgnored private let vaultLocationStore: VaultLocationStore
    @ObservationIgnored private let tabRestorationStore: TabRestorationStore
    @ObservationIgnored let moveToTrash: (URL) throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var watcher: VaultWatcher?
    @ObservationIgnored private var vaultReconciler: VaultReconciler?
    @ObservationIgnored private var backlinkGeneration = UUID()
    /// Applies backlink updates for the open Vault one at a time, merging bursts.
    @ObservationIgnored private var backlinkQueue: CoalescingQueue<BacklinkIndex.Update>?
    @ObservationIgnored var searchIndex: SearchIndex?
    @ObservationIgnored var searchIndexTask: Task<Void, Never>?
    @ObservationIgnored let brainRunStateStore: BrainRunStateStore
    @ObservationIgnored let tagGroupStore: TagGroupStore
    @ObservationIgnored var brainRun: BrainRun?
    @ObservationIgnored var brainRunTask: Task<Void, Never>?
    @ObservationIgnored var brainRunCleanupTask: Task<Void, Never>?
    @ObservationIgnored var brainRunCleanupID = UUID()
    /// Identifies the current Brain Run, so a run of a previous Vault reports nothing.
    @ObservationIgnored var brainRunID = UUID()
    @ObservationIgnored var isCheckingBrainRunBoundary = false
    @ObservationIgnored var needsBrainRunBoundaryRecheck = false

    init(
        vaultLocationStore: VaultLocationStore = VaultLocationStore(),
        tabRestorationStore: TabRestorationStore = TabRestorationStore(),
        settings: AppSettings = AppSettings(),
        brainRunStateStore: BrainRunStateStore = BrainRunStateStore(),
        tagGroupStore: TagGroupStore = TagGroupStore(),
        moveToTrash: @escaping (URL) throws -> Void = FileTrash.moveToTrash,
        now: @escaping () -> Date = Date.init
    ) {
        self.vaultLocationStore = vaultLocationStore
        self.tabRestorationStore = tabRestorationStore
        self.moveToTrash = moveToTrash
        self.settings = settings
        self.brainRunStateStore = brainRunStateStore
        self.tagGroupStore = tagGroupStore
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

    func presentImagePreview(_ content: ImagePreviewContent) {
        imagePreview.present(content)
    }

    func chooseVault(at url: URL) {
        let vault = Vault(rootURL: url)
        vaultLocationStore.remember(vault)
        open(vault)
    }

    func openToday() {
        openDailyEntry(todayDailyEntry)
    }

    var todayDailyEntry: DailyEntry {
        DailyEntry(date: now())
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
            showOpenedTab()
            backlinks = []
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
        refreshVisibleBacklinks()
    }

    /// Opens a Vault file in a tab, or selects its existing tab.
    @discardableResult
    func openNote(at fileURL: URL, newFileContent: String = "") -> NoteDocument? {
        let document = openNote(
            at: fileURL,
            newFileContent: newFileContent,
            errorPrefix: "Poznámku se nepodařilo otevřít"
        )
        refreshVisibleBacklinks()
        return document
    }

    /// Single entry point for opening a file from the sidebar.
    func openNote(relativePath: String) {
        _ = openExistingNote(relativePath: relativePath)
    }

    @discardableResult
    func openExistingNote(relativePath: String) -> NoteDocument? {
        guard let vault else { return nil }
        let fileURL = vault.rootURL
            .appending(path: relativePath, directoryHint: .notDirectory)
            .standardizedFileURL
        guard vault.contains(fileURL) else {
            errorMessage = "Poznámku se nepodařilo otevřít: \(CocoaError(.fileReadNoPermission).localizedDescription)"
            return nil
        }
        return openNote(at: fileURL)
    }

    func selectTab(documentID: NoteDocument.ID) {
        reveal = nil
        tabSession.select(documentID: documentID)
        persistTabs()
        refreshVisibleBacklinks()
    }

    func closeTab(documentID: NoteDocument.ID) {
        reveal = nil
        tabSession.closeTab(documentID: documentID)
        persistTabs()
        refreshVisibleBacklinks()
    }

    func hasOpenOrExistingNote(at fileURL: URL) -> Bool {
        tabSession.document(at: fileURL) != nil
            || FileManager.default.fileExists(atPath: fileURL.path)
    }

    func refreshTree() {
        vaultReconciler?.discardTreeScansInProgress()
        tree = vault?.scanTree() ?? .empty
    }

    func presentQuickOpen() {
        guard vault != nil else { return }
        isSearchPresented = false
        isQuickOpenPresented = true
    }

    /// Brings the sidebar and open tabs in line with the whole Vault on disk
    /// after outside changes (git, other editors, the Agent) that may have
    /// gone unreported, e.g. while the app was inactive.
    func reconcileWithDisk() {
        vaultReconciler?.submit(VaultChange(relativePaths: [], requiresFullRescan: true))
        scheduleBacklinks(BacklinkIndex.Update(changedPaths: [""]))
    }

    /// Where every batch of outside Vault changes lands; features that react to
    /// new files (e.g. Brain Notes after a Brain Run) hook in here.
    ///
    /// Search and the Brain Run boundary get each change at once; the sidebar
    /// tree and the affected tabs catch up in the background (`VaultReconciler`).
    func handleVaultChange(_ change: VaultChange) {
        updateSearchIndex(for: change)
        checkBrainRunBoundary(after: change)
        vaultReconciler?.submit(change)
        scheduleBacklinks(BacklinkIndex.Update(
            changedPaths: change.requiresFullRescan ? [""] : change.relativePaths
        ))
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
        // Exactly the files this save wrote are the user's, not the Agent's.
        defer { acceptUserWriteDuringBrainRun(of: document) }
        do {
            try document.save()
            refreshTree()
            updateSearchIndex(forSaved: document)
            persistTabs()
            updateBacklinks(for: document)
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
        resetBrainRun(for: vault)
        self.vault = vault
        tabSession = TabSession()
        startBacklinks(for: vault)
        selectedFolder = ""
        isQuickOpenPresented = false
        isSearchPresented = false
        loadTagGroups(for: vault)
        watch(vault)
        do {
            try vault.ensureBrainInstructions()
        } catch {
            errorMessage = "Výchozí _brain/AGENTS.md se nepodařilo vytvořit: \(error.localizedDescription)"
        }
        startSearchIndex(for: vault)
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
        rebuildBacklinks()
    }

    private func watch(_ vault: Vault) {
        watcher?.stop()
        vaultReconciler?.cancel()
        vaultReconciler = VaultReconciler(vault: vault, tabSession: tabSession) { [weak self] tree in
            guard let self, self.tree != tree else { return }
            self.tree = tree
        }
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
            showOpenedTab()
            return document
        } catch {
            errorMessage = "\(errorPrefix): \(error.localizedDescription)"
            return nil
        }
    }

    /// Every note opened in a tab is shown in the editor, so Tags mode gives way to Journal.
    private func showOpenedTab() {
        persistTabs()
        sidebarMode = .journal
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

    /// Recovery path: parses every note of the Vault again.
    func rebuildBacklinks() {
        scheduleBacklinks(BacklinkIndex.Update(rebuild: true))
    }

    private func updateBacklinks(for document: NoteDocument) {
        guard let vault, let relativePath = relativePath(for: document.fileURL, in: vault) else { return }
        scheduleBacklinks(BacklinkIndex.Update(savedContents: [relativePath: document.text]))
    }

    private func refreshVisibleBacklinks() {
        scheduleBacklinks(BacklinkIndex.Update())
    }

    /// A fresh index for `vault`; work queued for the previous Vault is dropped.
    private func startBacklinks(for vault: Vault) {
        backlinkQueue?.cancel()
        backlinks = []
        let index = BacklinkIndex()
        let generation = UUID()
        backlinkGeneration = generation
        backlinkQueue = CoalescingQueue(
            merge: { $0.merge($1) },
            perform: { [weak self] update in
                await index.apply(update, in: vault)
                guard let self, self.backlinkGeneration == generation else { return }
                await self.loadVisibleBacklinks(from: index, in: vault, generation: generation)
            }
        )
    }

    /// Applies `update` after the work already queued, then shows the active
    /// tab's backlinks.
    private func scheduleBacklinks(_ update: BacklinkIndex.Update) {
        guard vault != nil, let backlinkQueue else {
            backlinks = []
            return
        }
        backlinkQueue.submit(update)
    }

    private func loadVisibleBacklinks(
        from index: BacklinkIndex,
        in vault: Vault,
        generation: UUID
    ) async {
        guard backlinkGeneration == generation,
              let document,
              let relativePath = relativePath(for: document.fileURL, in: vault) else {
            backlinks = []
            return
        }
        let loaded = await index.backlinks(to: relativePath)
        guard backlinkGeneration == generation,
              let current = self.document,
              self.relativePath(for: current.fileURL, in: vault) == relativePath else { return }
        backlinks = loaded
    }

    func relativePath(for fileURL: URL, in vault: Vault) -> String? {
        let root = vault.rootURL.standardizedFileURL.path(percentEncoded: false) + "/"
        let path = fileURL.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(root) else { return nil }
        return String(path.dropFirst(root.count))
    }
}
