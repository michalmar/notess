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
        case .loaded:
            taskList
                .safeAreaInset(edge: .bottom) {
                    IndexStatusFooter(isIndexing: isIndexing, indexFailure: indexFailure)
                }
        }
    }

    private var taskList: some View {
        ScrollViewReader { proxy in
            List(selection: $browser.selectedTaskID) {
                ForEach(browser.groups) { group in
                    if browser.filter == .open {
                        Section(group.filter.title) {
                            rows(group.tasks)
                        }
                    } else {
                        rows(group.tasks)
                    }
                }
            }

            .contextMenu(forSelectionType: TaskOccurrence.ID.self) { ids in
                if let task = ids.first.flatMap(browser.listed) {
                    Button("Otevřít poznámku") { open(task) }
                }
            } primaryAction: { ids in
                if let task = ids.first.flatMap(browser.listed) { open(task) }
            }
            .task {
                // Back from the opened note: show the row the reader left from.
                await Task.yield()
                if let id = browser.selectedTaskID { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func rows(_ tasks: [TaskOccurrence]) -> some View {
        ForEach(tasks) { task in
            TaskRow(task: task, today: browser.today, open: open)
                .tag(task.id)
                .id(task.id)
        }
    }
}

/// One Task: its status, text and source note. The status is shown, not
/// changed here.
private struct TaskRow: View {
    let task: TaskOccurrence
    let today: Day
    let open: (TaskOccurrence) -> Void

    private var displayText: String {
        guard task.dueDate.day != nil else { return task.text }
        let text = NSMutableString(string: task.text)
        for marker in task.dueDate.markers.reversed() { text.replaceCharacters(in: marker.range, with: "") }
        return (text as String).trimmingCharacters(in: .whitespaces)
    }

    private var dateAccessibilityLabel: String {
        switch task.dueDate.state {
        case .missing: ""
        case .valid(let day): "Termín: \(day.isoString)"
        case .invalid: "Neplatný termín"
        }
    }

    @ViewBuilder
    private var dateLabel: some View {
        switch task.dueDate.state {
        case .missing:
            EmptyView()
        case .valid(let day):
            Label(day.taskDateLabel, systemImage: "calendar")
                .foregroundStyle(task.category(on: today) == .overdue ? .red : .secondary)
                .help("📅 \(day.isoString)")
                .accessibilityLabel(dateAccessibilityLabel)
        case .invalid:
            Label("Neplatný termín", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: task.isCompleted ? "checkmark.square" : "square")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayText.isEmpty ? " " : displayText)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                HStack(spacing: 8) {
                    Text(task.source.label)
                    dateLabel
                }
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
        .accessibilityLabel("\(task.isCompleted ? "Splněný" : "Nesplněný") úkol: \(task.text), \(task.source.label), \(dateAccessibilityLabel)")
        .accessibilityHint("Otevře poznámku s úkolem")
        .accessibilityAction { open(task) }
    }
}

private extension Day {
    var taskDateLabel: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        return date.formatted(Date.FormatStyle(
            date: .abbreviated, time: .omitted, calendar: calendar, timeZone: calendar.timeZone
        ))
    }
}

extension TaskFilter {
    var title: String {
        switch self {
        case .open: "Všechny nesplněné"
        case .overdue: "Po termínu"
        case .today: "Dnes"
        case .upcoming: "Nadcházející"
        case .undated: "Bez termínu"
        case .completed: "Splněné"
        }
    }

    var systemImage: String {
        switch self {
        case .open: "square"
        case .overdue: "exclamationmark.circle"
        case .today: "calendar"
        case .upcoming: "calendar.badge.clock"
        case .undated: "calendar.badge.minus"
        case .completed: "checkmark.square"
        }
    }

    var emptyTitle: String {
        switch self {
        case .open: "Žádné nesplněné úkoly"
        case .overdue: "Žádné úkoly po termínu"
        case .today: "Žádné úkoly na dnešek"
        case .upcoming: "Žádné nadcházející úkoly"
        case .undated: "Žádné úkoly bez termínu"
        case .completed: "Žádné splněné úkoly"
        }
    }

    var emptyDescription: String {
        switch self {
        case .open: "Uložené záznamy v Journalu ani poznámky nemají žádný nesplněný úkol."
        case .overdue: "Žádný uložený nesplněný úkol nemá termín před dneškem."
        case .today: "Žádný uložený nesplněný úkol nemá dnešní termín."
        case .upcoming: "Žádný uložený nesplněný úkol nemá budoucí termín."
        case .undated: "Každý uložený nesplněný úkol má platný termín."
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
