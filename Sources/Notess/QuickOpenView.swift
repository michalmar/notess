import NotessCore
import SwiftUI

struct QuickOpenView: View {
    let vault: Vault
    let open: (String) -> Void
    let dismiss: () -> Void

    @State private var files: [QuickOpenFile] = []
    @State private var query = ""
    @State private var selection: QuickOpenFile?
    @State private var isLoading = true
    @FocusState private var isSearchFocused: Bool

    private var matches: [QuickOpenFile] {
        QuickOpen.rankedFiles(matching: query, in: files)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Otevřít soubor…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit(openSelection)
            }
            .padding(14)

            Divider()

            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(matches, selection: $selection) { file in
                        QuickOpenRow(file: file)
                            .tag(file)
                    }
                    .listStyle(.plain)
                    .onChange(of: selection) { _, selected in
                        guard selected == nil else { return }
                        selection = matches.first
                    }
                }
            }
            .frame(height: 320)
        }
        .frame(width: 580)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(radius: 16)
        .onAppear {
            isSearchFocused = true
            loadFiles()
        }
        .onChange(of: query) { _, _ in
            selection = matches.first
        }
        .onMoveCommand { direction in
            moveSelection(direction)
        }
        .onExitCommand(perform: dismiss)
    }

    private func loadFiles() {
        Task {
            let scannedFiles = await Task.detached { vault.quickOpenFiles() }.value
            files = scannedFiles
            selection = matches.first
            isLoading = false
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard let index = selection.flatMap({ matches.firstIndex(of: $0) }) else {
            selection = matches.first
            return
        }
        switch direction {
        case .up:
            selection = matches[max(0, index - 1)]
        case .down:
            selection = matches[min(matches.count - 1, index + 1)]
        default:
            break
        }
    }

    private func openSelection() {
        guard let selection else { return }
        open(selection.relativePath)
        dismiss()
    }
}

private struct QuickOpenRow: View {
    let file: QuickOpenFile

    var body: some View {
        HStack {
            Image(systemName: file.isReadOnly ? "brain" : "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                Text(file.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if file.isReadOnly {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pouze pro čtení")
            }
        }
        .contentShape(.rect)
    }
}
