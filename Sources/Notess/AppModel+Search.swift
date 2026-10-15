import Foundation
import NotessCore
import NotessEditor

extension AppModel {
    /// Cmd+Shift+F: the Spotlight-style search over Sections.
    func presentSearch() {
        guard vault != nil else { return }
        isQuickOpenPresented = false
        isSearchPresented = true
    }

    /// Opens the note of a search result in a tab and scrolls to its Section.
    func openSearchResult(_ result: SearchResult) {
        isSearchPresented = false
        openSection(relativePath: result.relativePath, title: result.title, ordinal: result.ordinal)
    }

    /// Opens the Daily Entry of a Tag Timeline Section for editing and scrolls to the Section.
    func openTimelineSection(_ section: TagTimelineSection) {
        openSection(relativePath: section.relativePath, title: section.title, ordinal: section.ordinal)
    }

    /// Opens a note in Journal mode, reusing its tab (and any unsaved text), and
    /// reveals the Section as found in the tab's current text.
    private func openSection(relativePath: String, title: String?, ordinal: Int) {
        guard let document = openExistingNote(relativePath: relativePath) else { return }
        let section = SearchSection.locate(title: title, ordinal: ordinal, in: document.text)
        let range = section?.headingRange ?? NSRange(location: section?.range.location ?? 0, length: 0)
        reveal = EditorReveal(documentID: document.id, range: range)
    }

    /// Reloads the Tags and the selected timeline while Tags mode is shown;
    /// called whenever the index or the mode changes.
    func refreshTagTimeline() {
        guard sidebarMode == .tags else { return }
        let browser = tagTimeline
        Task { await browser.refresh() }
    }

    func selectTimelineTag(_ tag: String?) {
        let browser = tagTimeline
        Task { await browser.select(tag) }
    }

    /// Opens the Vault's index (a cache outside the Vault) and catches up with
    /// changes made while the app was closed, in the background.
    func startSearchIndex(for vault: Vault) {
        searchIndexTask?.cancel()
        let index = SearchIndex(vault: vault, databaseURL: SearchIndex.defaultDatabaseURL(for: vault))
        searchIndex = index
        tagTimeline.connect(index)
        refreshTagTimeline()
        runIndexing(index, errorPrefix: "Index hledání se nepodařilo aktualizovat") {
            try await index.synchronize()
        }
    }

    /// Throws the index away and builds it again from the files.
    func rebuildSearchIndex() {
        guard let index = searchIndex else { return }
        searchIndexTask?.cancel()
        runIndexing(index, errorPrefix: "Index hledání se nepodařilo přegenerovat") {
            try await index.rebuild()
        }
    }

    func updateSearchIndex(for change: VaultChange) {
        guard let index = searchIndex else { return }
        if change.requiresFullRescan {
            updateSearchIndex(index) { try await index.synchronize() }
        } else {
            let paths = change.relativePaths
            updateSearchIndex(index) { try await index.update(relativePaths: paths) }
        }
    }

    func updateSearchIndex(forSaved document: NoteDocument) {
        guard let index = searchIndex else { return }
        let url = document.fileURL
        updateSearchIndex(index) { try await index.update(fileAt: url) }
    }

    /// Catches up with outside changes the watcher may have missed (it can
    /// fail to start); unchanged files are skipped by their stamps.
    func synchronizeSearchIndex() {
        guard let index = searchIndex, !isIndexing else { return }
        updateSearchIndex(index) { try await index.synchronize() }
    }

    private func updateSearchIndex(_ index: SearchIndex, _ work: @escaping @Sendable () async throws -> Void) {
        Task { [weak self] in
            let failure: Error?
            do {
                try await work()
                failure = nil
            } catch is CancellationError {
                return
            } catch {
                failure = error
            }
            guard let self, self.searchIndex === index else { return }
            self.searchIndexRevision += 1
            if let failure {
                self.errorMessage = "Index hledání se nepodařilo aktualizovat: \(failure.localizedDescription)"
            }
        }
    }

    private func runIndexing(
        _ index: SearchIndex,
        errorPrefix: String,
        _ work: @escaping @Sendable () async throws -> Void
    ) {
        isIndexing = true
        searchIndexTask = Task { [weak self] in
            let failure: Error?
            do {
                try await work()
                failure = nil
            } catch is CancellationError {
                return
            } catch {
                failure = error
            }
            guard let self, self.searchIndex === index else { return }
            self.isIndexing = false
            self.searchIndexRevision += 1
            if let failure {
                self.errorMessage = "\(errorPrefix): \(failure.localizedDescription)"
            }
        }
    }
}
