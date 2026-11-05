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
    /// unsaved text, and reveals the Task while it is still where it was saved.
    /// Otherwise the note opens with a warning and nothing else is revealed.
    /// A note that no longer exists is not created.
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
        guard let range = task.range(in: document.text) else {
            reveal = nil
            errorMessage = "Úkol „\(task.text)“ už v poznámce není tam, kde byl uložen "
                + "(neuložené úpravy ho posunuly nebo změnily). Poznámka je otevřená bez přechodu na úkol."
            return
        }
        reveal = EditorReveal(documentID: document.id, range: range)
    }
}
