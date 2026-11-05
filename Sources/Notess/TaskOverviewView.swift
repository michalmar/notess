import NotessCore
import SwiftUI

/// Tasks mode of the sidebar (Úkoly): the Task Overview's filters, one
/// selected at a time.
struct TaskFilterList: View {
    let model: AppModel

    private var selection: Binding<TaskFilter?> {
        Binding(
            get: { model.taskOverview.filter },
            set: { if let filter = $0 { model.selectTaskFilter(filter) } }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section("Úkoly") {
                ForEach(TaskFilter.allCases, id: \.self) { filter in
                    Label(filter.title, systemImage: filter.systemImage)
                        .tag(filter)
                }
            }
        }
    }
}

/// Tasks mode detail: the saved Tasks the selected filter lists (see
/// `GLOSSARY.md`, Task Overview). Rows are read-only; activating one opens
/// its note.
struct TaskOverviewView: View {
    @Bindable var browser: TaskOverviewBrowser
    let isIndexing: Bool
    let indexFailure: String?
    let open: (TaskOccurrence) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(browser.filter.title)
            .navigationSubtitle("")
    }

    @ViewBuilder
    private var content: some View {
        switch browser.tasks {
        case .loading:
            ProgressView("Načítám úkoly…")
        case .failed(let message):
            ContentUnavailableView(
                "Úkoly se nepodařilo načíst",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let tasks) where tasks.isEmpty:
            EmptyIndexedContent(
                isIndexing: isIndexing,
                indexFailure: indexFailure,
                title: browser.filter.emptyTitle,
                description: browser.filter.emptyDescription,
                systemImage: "checklist"
            )
        case .loaded(let tasks):
            taskList(tasks)
                .safeAreaInset(edge: .bottom) {
                    IndexStatusFooter(isIndexing: isIndexing, indexFailure: indexFailure)
                }
        }
    }

    private func taskList(_ tasks: [TaskOccurrence]) -> some View {
        ScrollViewReader { proxy in
            List(selection: $browser.selectedTaskID) {
                ForEach(tasks) { task in
                    TaskRow(task: task, open: open)
                        .id(task.id)
                }
            }
            .contextMenu(forSelectionType: TaskOccurrence.ID.self) { ids in
                if let task = ids.first.flatMap(browser.listed) {
                    Button("Otevřít poznámku") { open(task) }
                }
            } primaryAction: { ids in
                if let task = ids.first.flatMap(browser.listed) { open(task) }
            }
            .onAppear {
                // Back from the opened note: show the row the reader left from.
                if let id = browser.selectedTaskID { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// One Task: its status, text and source note. The status is shown, not
/// changed here.
private struct TaskRow: View {
    let task: TaskOccurrence
    let open: (TaskOccurrence) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: task.isCompleted ? "checkmark.square" : "square")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.text.isEmpty ? " " : task.text)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                Text(task.source.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                open(task)
            } label: {
                Label("Otevřít", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.link)
            .help("Otevře poznámku s úkolem k úpravám a ukáže úkol")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.isCompleted ? "Splněný" : "Nesplněný") úkol: \(task.text), \(task.source.label)")
        .accessibilityHint("Otevře poznámku s úkolem")
        .accessibilityAction { open(task) }
    }
}

extension TaskFilter {
    var title: String {
        switch self {
        case .open: "Všechny nesplněné"
        case .completed: "Splněné"
        }
    }

    var systemImage: String {
        switch self {
        case .open: "square"
        case .completed: "checkmark.square"
        }
    }

    var emptyTitle: String {
        switch self {
        case .open: "Žádné nesplněné úkoly"
        case .completed: "Žádné splněné úkoly"
        }
    }

    var emptyDescription: String {
        switch self {
        case .open: "Uložené záznamy v Journalu ani poznámky nemají žádný nesplněný úkol."
        case .completed: "Uložené záznamy v Journalu ani poznámky nemají žádný splněný úkol."
        }
    }
}

extension TaskSource {
    /// Where the Task is written: the Daily Entry's date, or the Free Note's
    /// name with its folder.
    var label: String {
        switch self {
        case .dailyEntry(let day): day.isoString
        case .freeNote(let name, let folder): folder.isEmpty ? name : "\(name) — \(folder)"
        }
    }
}
