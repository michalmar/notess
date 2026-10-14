import Foundation
import NotessCore
import Observation

/// App-wide state: which Vault is open and which note is being edited.
@MainActor
@Observable
final class AppModel {
    private(set) var vault: Vault?
    private(set) var document: NoteDocument?
    var errorMessage: String?

    @ObservationIgnored private let vaultLocationStore: VaultLocationStore
    @ObservationIgnored private let now: () -> Date

    init(vaultLocationStore: VaultLocationStore = VaultLocationStore(), now: @escaping () -> Date = Date.init) {
        self.vaultLocationStore = vaultLocationStore
        self.now = now
        if let saved = vaultLocationStore.savedVault() {
            open(saved)
        }
    }

    var canChangeVault: Bool {
        document?.hasUnsavedChanges != true
    }

    func chooseVault(at url: URL) {
        let vault = Vault(rootURL: url)
        vaultLocationStore.remember(vault)
        open(vault)
    }

    func openToday() {
        guard let vault else { return }
        do {
            document = try vault.openDailyEntry(DailyEntry(date: now()))
        } catch {
            errorMessage = "Dnešní záznam se nepodařilo otevřít: \(error.localizedDescription)"
        }
    }

    func save() {
        guard let document else { return }
        do {
            try document.save()
        } catch {
            errorMessage = "Uložení se nezdařilo: \(error.localizedDescription)"
        }
    }

    private func open(_ vault: Vault) {
        self.vault = vault
        document = nil
        openToday()
    }
}
