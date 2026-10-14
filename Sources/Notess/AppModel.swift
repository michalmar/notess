import Foundation
import NotessCore
import Observation

/// App-wide state: which Vault is open and which note is being edited.
@MainActor
@Observable
final class AppModel {
    private(set) var vault: Vault?
    private(set) var document: NoteDocument?
    private(set) var tree: VaultTree = .empty
    /// Vault-relative folder chosen in the Notes section ("" is the Vault root); target for new Free Notes.
    var selectedFolder = ""
    var errorMessage: String?
    let settings: AppSettings

    @ObservationIgnored private let vaultLocationStore: VaultLocationStore
    @ObservationIgnored private let now: () -> Date

    init(
        vaultLocationStore: VaultLocationStore = VaultLocationStore(),
        settings: AppSettings = AppSettings(),
        now: @escaping () -> Date = Date.init
    ) {
        self.vaultLocationStore = vaultLocationStore
        self.settings = settings
        self.now = now
        if let saved = vaultLocationStore.savedVault() {
            open(saved)
        }
    }

    var hasUnsavedChanges: Bool {
        document?.hasUnsavedChanges == true
    }

    func chooseVault(at url: URL) {
        let vault = Vault(rootURL: url)
        vaultLocationStore.remember(vault)
        open(vault)
    }

    func openToday() {
        openDailyEntry(DailyEntry(date: now()))
    }

    func openDailyEntry(_ entry: DailyEntry) {
        guard let vault, !isShowing(vault.url(for: entry)), canLeaveCurrentDocument() else { return }
        do {
            document = try vault.openDailyEntry(entry)
        } catch {
            errorMessage = "Záznam se nepodařilo otevřít: \(error.localizedDescription)"
        }
    }

    /// Single entry point for opening a file from the sidebar; tabs (#3) replace its body.
    func openNote(relativePath: String) {
        guard let vault, !isShowing(vault.rootURL.appending(path: relativePath)), canLeaveCurrentDocument() else { return }
        do {
            document = try vault.openNote(relativePath: relativePath)
        } catch {
            errorMessage = "Poznámku se nepodařilo otevřít: \(error.localizedDescription)"
        }
    }

    func refreshTree() {
        tree = vault?.scanTree() ?? .empty
    }

    /// Returns `false` if saving failed; the error is then in `errorMessage`.
    @discardableResult
    func save() -> Bool {
        guard let document else { return true }
        do {
            try document.save()
            refreshTree()
            return true
        } catch {
            errorMessage = "Uložení se nezdařilo: \(error.localizedDescription)"
            return false
        }
    }

    private func open(_ vault: Vault) {
        self.vault = vault
        document = nil
        selectedFolder = ""
        refreshTree()
        openToday()
    }

    private func isShowing(_ url: URL) -> Bool {
        document?.fileURL.standardizedFileURL == url.standardizedFileURL
    }

    // Until tabs exist only one document is open; never silently drop its edits.
    private func canLeaveCurrentDocument() -> Bool {
        guard hasUnsavedChanges else { return true }
        errorMessage = "Nejdřív uložte změny (⌘S)."
        return false
    }
}
