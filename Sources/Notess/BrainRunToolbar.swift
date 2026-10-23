import NotessCore
import SwiftUI

/// Toolbar: Brain Run status (opens the log), "Zpracovat" / "Zrušit", and the Brain Conversation toggle.
struct BrainRunToolbarItems: View {
    @Bindable var model: AppModel

    var body: some View {
        Button {
            model.isBrainRunLogPresented.toggle()
        } label: {
            BrainRunStatusLabel(phase: model.brainRunPhase, lastSuccess: model.lastSuccessfulBrainRun)
        }
        .help(statusHelp)
        .popover(isPresented: $model.isBrainRunLogPresented, arrowEdge: .bottom) {
            BrainRunLogView(log: model.brainRunLog)
        }

        if model.isBrainRunActive {
            Button {
                model.cancelBrainRun()
            } label: {
                Label("Zrušit", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(model.brainRunPhase == .cancelling)
            .help("Ukončit Copilot CLI; běh se nepočítá jako úspěšný")
        } else {
            Button {
                model.startBrainRun()
            } label: {
                Label("Zpracovat", systemImage: "brain")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(model.brainConversation.isTurnActive)
            .help(model.brainConversation.isTurnActive
                ? "Agent odpovídá v konverzaci; Brain Run lze spustit, až skončí"
                : "Agent zpracuje poznámky změněné od posledního úspěšného Brain Runu do _brain/")
        }

        Button {
            model.isBrainConversationPresented.toggle()
        } label: {
            Label("Konverzace", systemImage: "bubble.left.and.text.bubble.right")
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .help(model.isBrainConversationPresented ? "Skrýt konverzaci (⇧⌘B)" : "Zeptat se na poznámky (⇧⌘B)")
    }

    private var statusHelp: String {
        if case .failed(let message) = model.brainRunPhase {
            return "\(message)\nKliknutím otevřete log."
        }
        return "Zobrazit log Brain Runu"
    }
}

private struct BrainRunStatusLabel: View {
    let phase: BrainRunPhase
    let lastSuccess: Date?

    var body: some View {
        HStack(spacing: 6) {
            switch phase {
            case .idle:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                if let lastSuccess {
                    Text("Zpracováno \(lastSuccess, format: .relative(presentation: .named))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Zatím nezpracováno")
                        .foregroundStyle(.secondary)
                }
            case .running:
                ProgressView().controlSize(.small)
                Text("Běží…")
            case .cancelling:
                ProgressView().controlSize(.small)
                Text("Ruším…")
            case .succeeded, .nothingToProcess:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(phase == .nothingToProcess ? "Hotovo – nic nového" : "Hotovo")
            case .cancelled:
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                Text("Zrušeno")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Chyba")
            }
        }
        .fixedSize()
    }
}

/// The run's stdout and stderr, scrolled to the end as it grows.
private struct BrainRunLogView: View {
    let log: BrainRunLog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log Brain Runu")
                    .font(.headline)
                Spacer()
                Button("Kopírovat") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text, forType: .string)
                }
                .disabled(log.text.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.text.isEmpty ? "Zatím žádný běh." : log.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(log.text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .frame(height: 1)
                        .id("end")
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: log.text) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding(12)
        .frame(width: 560, height: 380)
    }
}
