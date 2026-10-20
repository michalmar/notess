import AppKit
import NotessCore

/// Where Tag completion looks up suggestions, typically the current Vault's
/// saved Tags. `id` identifies the vocabulary (e.g. the Vault): when it
/// changes, open completion closes and pending lookups are discarded.
/// `revision` counts changes of the same vocabulary (e.g. the index caught up
/// with saved notes): when it changes, open completion looks up again.
public struct TagSuggestionSource {
    public let id: AnyHashable
    public let revision: Int
    /// Saved Tags matching a prefix (as written, without `#`). Runs off the
    /// typing path; the editor normalises, deduplicates and sorts the result.
    public let suggestions: @MainActor (String) async throws -> [String]

    public init(id: AnyHashable, revision: Int = 0, suggestions: @escaping @MainActor (String) async throws -> [String]) {
        self.id = id
        self.revision = revision
        self.suggestions = suggestions
    }
}

/// Tag completion in a `MarkdownTextView`: typing or deleting in a Tag prefix
/// looks up saved Tags asynchronously and shows them in a `TagSuggestionList`;
/// Tab replaces the whole Tag with the selected one.
///
/// Every lookup belongs to a generation. Any edit, caret move, dismissal,
/// acceptance or change of note or vocabulary starts a new generation, so a
/// late response can neither show stale suggestions nor edit the text.
@MainActor
final class TagCompleter {
    private unowned let textView: MarkdownTextView
    private var generation = 0
    private var lookup: Task<Void, Never>?
    /// The Tag being completed; nil when completion is closed.
    private(set) var context: TagCompletionContext?
    /// The shown suggestions; empty while closed or waiting for a lookup.
    private(set) var suggestions: [String] = []
    /// The highlighted suggestion; nil while waiting for a lookup, so a
    /// pending lookup never takes Tab.
    private(set) var selectedIndex: Int?
    /// The suggestion to highlight again once the pending lookup answers.
    private var pendingSelection: String?
    /// Set after a failure has been reported, until a lookup succeeds or the
    /// vocabulary changes, so a broken index does not report every keystroke.
    private var hasReportedFailure = false
    private lazy var list: TagSuggestionList = {
        let list = TagSuggestionList()
        list.onChoose = { [weak self] index in _ = self?.choose(index) }
        return list
    }()

    init(textView: MarkdownTextView) {
        self.textView = textView
    }

    // MARK: Opening and refreshing

    /// Reacts to a text change. `editedRange` is the changed text after a
    /// typing or deleting edit; nil for changes that must not open completion
    /// (undo, redo, loading a note).
    func textDidChange(editedRange: NSRange?) {
        guard let editedRange, let source = textView.tagSuggestionSource,
              let context = textView.tagCompletionContextAtCaret(),
              editedRange.location >= context.tokenRange.location,
              NSMaxRange(editedRange) <= NSMaxRange(context.tokenRange)
        else {
            dismiss()
            return
        }
        let previous = self.context
        let previousSuggestions = suggestions
        pendingSelection = selectedIndex.map { suggestions[$0] } ?? pendingSelection
        generation += 1
        lookup?.cancel()
        self.context = context

        // While the prefix only grows, the shown suggestions stay on screen,
        // narrowed, so the list does not flicker; nothing is highlighted until
        // the lookup confirms them.
        if let previous, !previousSuggestions.isEmpty,
           context.normalizedPrefix.hasPrefix(previous.normalizedPrefix) {
            show(TagCompletion.candidates(matching: context.prefix, in: previousSuggestions), highlighting: nil)
        } else {
            show([], highlighting: nil)
        }

        startLookup(for: context, source: source)
    }

    /// The vocabulary changed without changing identity (saved notes were
    /// indexed). Refreshes only a completion that is still open at its
    /// original context, never opens one; the shown suggestions and their
    /// highlight stay until the answer arrives.
    func vocabularyDidRefresh() {
        guard let context, let source = textView.tagSuggestionSource else { return }
        guard textView.tagCompletionContextAtCaret() == context else {
            dismiss()
            return
        }
        pendingSelection = selectedIndex.map { suggestions[$0] } ?? pendingSelection
        generation += 1
        lookup?.cancel()
        startLookup(for: context, source: source)
    }

    private func startLookup(for context: TagCompletionContext, source: TagSuggestionSource) {
        let generation = generation
        let prefix = context.prefix
        lookup = Task { [weak self] in
            let result: Result<[String], Error>
            do {
                result = .success(try await source.suggestions(prefix))
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == generation else { return }
            lookup = nil
            switch result {
            case .success(let tags):
                hasReportedFailure = false
                let tags = TagCompletion.candidates(matching: prefix, in: tags)
                show(tags, highlighting: pendingSelection.flatMap(tags.firstIndex(of:)) ?? 0)
                pendingSelection = nil
                if suggestions.isEmpty { dismiss() }
            case .failure(let error):
                dismiss()
                guard !(error is CancellationError), !hasReportedFailure else { return }
                hasReportedFailure = true
                textView.onTagSuggestionFailure?(error)
            }
        }
    }

    // MARK: Closing

    /// Closes completion and discards any pending lookup.
    func dismiss() {
        generation += 1
        lookup?.cancel()
        lookup = nil
        context = nil
        pendingSelection = nil
        show([], highlighting: nil)
    }

    /// Closes completion unless the selection is still the caret it was opened at.
    func selectionDidChange() {
        guard let context else { return }
        let selection = textView.selectedRange()
        if selection.length != 0 || selection.location != context.caret {
            dismiss()
        }
    }

    /// The vocabulary changed (e.g. another Vault): old results no longer apply.
    func sourceDidChange() {
        hasReportedFailure = false
        dismiss()
    }

    // MARK: Choosing

    /// Moves the highlight `offset` rows, stopping at the first and last
    /// suggestion. Returns false when no suggestion is actionable, so the key
    /// keeps its usual meaning (moving the caret).
    func moveSelection(by offset: Int) -> Bool {
        guard context != nil, let selectedIndex else { return false }
        let index = max(0, min(selectedIndex + offset, suggestions.count - 1))
        if index != selectedIndex {
            self.selectedIndex = index
            list.select(index)
        }
        return true
    }

    // MARK: Accepting

    /// Replaces the Tag at the caret with the selected suggestion, as one
    /// undoable edit. Returns false, changing nothing, when no suggestion is
    /// actionable, so the key keeps its usual meaning.
    func acceptSelected() -> Bool {
        guard let selectedIndex else { return false }
        return accept(suggestions[selectedIndex])
    }

    /// Accepts the suggestion in row `index` of the shown list, as clicked
    /// or pressed through accessibility; it need not be the highlighted one.
    private func choose(_ index: Int) -> Bool {
        guard list.superview != nil, list.tags.indices.contains(index) else { return false }
        return accept(list.tags[index])
    }

    /// Replaces the Tag at the caret with `tag`, provided the caret is still
    /// in the Tag the suggestions were looked up for.
    private func accept(_ tag: String) -> Bool {
        guard let context else { return false }
        guard textView.tagCompletionContextAtCaret() == context else {
            dismiss()
            return false
        }
        dismiss()
        return textView.applyTagCompletion(replacing: context.tokenRange, with: "#" + tag)
    }

    // MARK: Presentation

    private func show(_ tags: [String], highlighting index: Int?) {
        suggestions = tags
        selectedIndex = tags.isEmpty ? nil : index
        guard !tags.isEmpty, let context, let container = textView.enclosingScrollView else {
            list.removeFromSuperview()
            return
        }
        list.show(tags, selectedIndex: selectedIndex)
        if list.superview !== container {
            container.addSubview(list, positioned: .above, relativeTo: nil)
            observeScrolling(of: container)
        }
        position(below: context.tokenRange, in: container)
    }

    private var scrollObserver: (any NSObjectProtocol)?

    /// Keeps the list next to its Tag while the editor scrolls.
    private func observeScrolling(of container: NSScrollView) {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        container.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: container.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    /// Places the list under the Tag (or above it near the bottom edge),
    /// inside the visible part of the editor.
    func reposition() {
        guard let context, list.superview != nil, let container = textView.enclosingScrollView else { return }
        position(below: context.tokenRange, in: container)
    }

    /// Puts the list under the Tag if it fits there, else above it; if it fits
    /// on neither side, on the roomier side, shortened to whole rows, so it
    /// never covers the Tag. It always stays inside the visible editor area.
    private func position(below range: NSRange, in container: NSScrollView) {
        let gap: CGFloat = 2
        let anchor = textView.rect(forCharacterRange: NSRange(location: range.location, length: min(range.length, 1)))
        let visible = textView.visibleRect
        // The editor is flipped: "below" is towards larger y.
        let spaceBelow = visible.maxY - anchor.maxY - gap
        let spaceAbove = anchor.minY - gap - visible.minY
        let preferred = list.preferredHeight
        let opensBelow: Bool
        let height: CGFloat
        if preferred <= spaceBelow {
            (opensBelow, height) = (true, preferred)
        } else if preferred <= spaceAbove {
            (opensBelow, height) = (false, preferred)
        } else {
            opensBelow = spaceBelow >= spaceAbove
            height = list.height(fitting: max(spaceBelow, spaceAbove))
        }
        let size = NSSize(width: min(TagSuggestionList.width, visible.width), height: min(height, visible.height))
        var frame = NSRect(
            origin: NSPoint(x: anchor.minX, y: opensBelow ? anchor.maxY + gap : anchor.minY - gap - size.height),
            size: size
        )
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - size.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - size.height))
        list.frame = container.convert(frame, from: textView)
        list.scrollSelectionToVisible()
    }

    /// The shown rows as the user reads them (`#tag`), for tests and accessibility checks.
    var visibleRows: [String] {
        list.superview == nil ? [] : list.tags.map { "#" + $0 }
    }

    /// The highlighted row (`#tag`), if the list is shown.
    var selectedRow: String? {
        guard list.superview != nil, let index = list.selectedIndex else { return nil }
        return "#" + list.tags[index]
    }

    /// The shown rows not scrolled out of the list (`#tag`).
    var rowsInView: [String] {
        list.superview == nil ? [] : list.rowsInView.map { "#" + list.tags[$0] }
    }
}
