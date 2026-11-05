import Foundation
import NotessCore
import NotessEditor

extension AppModel {
    /// Reloads the Task Overview while Tasks mode is shown; called whenever
    /// the index or the mode changes.
    func refreshTaskOverview() {
        guard sidebarMode == .tasks else { return }
        let browser = taskOverview
        Task { await browser.refresh() }
    }

    func selectTaskFilter(_ filter: TaskFilter) {
        let browser = taskOverview
        Task { await browser.select(filter) }
    }

    /// Opens the note a listed Task comes from, reusing its tab and any
    /// unsaved text, and reveals the Task where it is now, also when unsaved
    /// edits moved it (`TaskOccurrence.locate`). When the Task was changed,
    /// removed or cannot be told from identical Tasks, the note opens with a
    /// warning and nothing is revealed. A note that no longer exists is not created.
    func openTask(_ task: TaskOccurrence) {
        guard let vault, taskOverview.listed(task.id) == task else { return }
        taskOverview.selectedTaskID = task.id
        let url = vault.rootURL.appending(path: task.relativePath, directoryHint: .notDirectory).standardizedFileURL
        guard hasOpenOrExistingNote(at: url) else {
            errorMessage = "Poznámka s úkolem „\(task.text)“ už ve Vaultu neexistuje."
            updateSearchIndex(for: VaultChange(relativePaths: [task.relativePath]))
            return
        }
        guard let document = openExistingNote(relativePath: task.relativePath) else { return }
        switch task.locate(in: document.text) {
        case .found(let range):
            reveal = EditorReveal(documentID: document.id, range: range)
        case .missing:
            reveal = nil
            errorMessage = "Úkol „\(task.text)“ už v poznámce není tak, jak byl uložen "
                + "(neuložené úpravy ho změnily, přesunuly pod jiný nadpis nebo odstranily). "
                + "Poznámka je otevřená bez přechodu na úkol."
        case .ambiguous:
            reveal = nil
            errorMessage = "Úkol „\(task.text)“ je v poznámce víckrát a po neuložených úpravách nejde poznat, "
                + "který z nich to je. Poznámka je otevřená bez přechodu na úkol."
        }
    }
}
