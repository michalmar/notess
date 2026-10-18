import NotessCore
import SwiftUI

struct QuickOpenView: View {
    let vault: Vault
    let open: (String) -> Void
    let dismiss: () -> Void

    @State private var quickOpen = QuickOpenState()
    @State private var isLoading = true
    @State private var loadToken = UUID()
    @FocusState private var isSearchFocused: Bool

    private var queryBinding: Binding<String> {
        Binding(
            get: { quickOpen.query },
            set: { quickOpen.updateQuery($0) }
        )
    }

    private var selectionBinding: Binding<QuickOpenFile?> {
        Binding(
            get: { quickOpen.selection },
            set: { quickOpen.select($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Otevřít soubor…", text: queryBinding)
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
                } else if quickOpen.matches.isEmpty {
                    ContentUnavailableView.search(text: quickOpen.query)
                } else {
                    List(quickOpen.matches, selection: selectionBinding) { file in
                        QuickOpenRow(file: file)
                            .tag(file)
                    }
                    .listStyle(.plain)
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
        .onDisappear {
            loadToken = UUID()
        }
        .onMoveCommand { direction in
            moveSelection(direction)
        }
        .onExitCommand(perform: dismiss)
    }

    private func loadFiles() {
        let token = UUID()
        loadToken = token
        Task {
            let scannedFiles = await Task.detached { vault.quickOpenFiles() }.value
            guard loadToken == token, !Task.isCancelled else { return }
            quickOpen.replaceCandidates(scannedFiles)
            isLoading = false
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .up:
            quickOpen.moveSelection(upward: true)
        case .down:
            quickOpen.moveSelection(upward: false)
        default:
            break
        }
    }

    private func openSelection() {
        guard let selection = quickOpen.selection else { return }
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
