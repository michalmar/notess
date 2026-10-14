import NotessCore
import SwiftUI

private enum SidebarItem: Hashable {
    case day(Day)
    case note(String)
    case folder(String)
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Journal") {
                Button {
                    model.openToday()
                    syncSelectionWithDocument()
                } label: {
                    Label("Dnes", systemImage: "calendar")
                }
                ForEach(model.tree.journal.years) { year in
                    DisclosureGroup(String(year.year)) {
                        ForEach(year.months) { month in
                            DisclosureGroup(Self.monthName(month.month)) {
                                ForEach(month.days, id: \.self) { day in
                                    Label(day.isoString, systemImage: "doc.text")
                                        .tag(SidebarItem.day(day))
                                }
                            }
                        }
                    }
                }
            }
            Section("Notes") {
                Label("Vault", systemImage: "tray.full")
                    .tag(SidebarItem.folder(""))
                FolderContents(folder: model.tree.notes)
            }
            Section("Brain") {
                if model.vault?.isBrainFolderAvailable ?? false {
                    Label("Instrukce (AGENTS.md)", systemImage: "gearshape")
                        .tag(SidebarItem.note(Vault.brainInstructionsRelativePath))
                }
                ForEach(model.tree.brain.groups) { group in
                    DisclosureGroup {
                        ForEach(group.notes) { note in
                            Label(note.title, systemImage: "brain")
                                .tag(SidebarItem.note(note.relativePath))
                        }
                    } label: {
                        Label(group.title, systemImage: "folder")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.document?.id) { _, _ in
            syncSelectionWithDocument()
        }
        .onChange(of: selection) { _, item in
            switch item {
            case .day(let day):
                model.openDailyEntry(DailyEntry(day: day))
                syncSelectionWithDocument()
            case .note(let path):
                model.openNote(relativePath: path)
                syncSelectionWithDocument()
            case .folder(let path): model.selectedFolder = path
            case nil: break
            }
        }
        .onAppear { selection = .folder(model.selectedFolder) }
    }

    /// Keeps the highlight on the file that is actually open, e.g. after a refused or failed open.
    private func syncSelectionWithDocument() {
        guard let vault = model.vault, let url = model.document?.fileURL else { return }
        let root = vault.rootURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { return }
        let relative = String(path.dropFirst(root.count))
        switch NoteKind.classify(relativePath: relative) {
        case .dailyEntry: selection = DailyEntry.day(forRelativePath: relative).map(SidebarItem.day)
        case .freeNote, .brainNote: selection = .note(relative)
        default: break
        }
    }

    private static func monthName(_ month: Int) -> String {
        let names = Calendar.current.standaloneMonthSymbols
        return names.indices.contains(month - 1) ? names[month - 1].capitalized : String(month)
    }
}

private struct FolderContents: View {
    let folder: NotesFolder

    var body: some View {
        ForEach(folder.folders) { sub in
            DisclosureGroup {
                FolderContents(folder: sub)
            } label: {
                Label(sub.name, systemImage: "folder")
                    .tag(SidebarItem.folder(sub.relativePath))
            }
        }
        ForEach(folder.notes) { note in
            Label(note.title, systemImage: "doc.text")
                .tag(SidebarItem.note(note.relativePath))
        }
    }
}
