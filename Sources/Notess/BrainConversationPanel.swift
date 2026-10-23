import NotessCore
import SwiftUI

/// The right-hand Brain Conversation panel: questions about the saved Vault, streamed
/// answers with the Agent's activity, and follow-ups in the same conversation.
struct BrainConversationPanel: View {
    let state: BrainConversationState
    /// A Brain Run owns the Vault, so no question can be sent.
    let isBrainRunActive: Bool
    let hasUnsavedChanges: Bool
    let onAsk: (String) -> Bool
    let onStop: () -> Void
    let onClose: () -> Void

    @State private var draft = ""
    @FocusState private var isInputFocused: Bool

    static let inputPlaceholder = "Zeptejte se na své poznámky…"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            BrainConversationTranscript(conversation: state.conversation)
            Divider()
            input
        }
        .frame(maxHeight: .infinity)
        .background(.background)
        .onAppear { isInputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Konverzace", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Zavřít panel konverzace")
            .accessibilityLabel("Zavřít konverzaci")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let refusal = state.refusal {
                Label(refusal, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if hasUnsavedChanges {
                Label("Agent vidí jen uložené soubory; neuložené změny nezná.", systemImage: "square.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(Self.inputPlaceholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .onSubmit(send)
                switch control {
                case .stop(let isEnabled):
                    Button(action: onStop) {
                        Label("Zastavit", systemImage: "stop.fill")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!isEnabled)
                    .help("Zastavit Agenta; rozepsaná odpověď zůstane označená jako neúplná")
                    .accessibilityLabel("Zastavit")
                case .send(let isEnabled):
                    Button(action: send) {
                        Label("Odeslat", systemImage: "arrow.up.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!isEnabled)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(isBrainRunActive ? "Běží Brain Run; zeptat se můžete, až doběhne" : "Odeslat dotaz (↩)")
                    .accessibilityLabel("Odeslat")
                }
            }
            Text("Agent čte uložené soubory Vaultu a do Vaultu nemůže zapisovat. Mimo Vault (síť, jiné soubory) omezen není.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    /// The button beside the question field: Send between turns, Stop during one.
    enum Control: Equatable {
        case send(isEnabled: Bool)
        case stop(isEnabled: Bool)
    }

    static func control(for conversation: BrainConversation, isBrainRunActive: Bool, draft: String) -> Control {
        if let active = conversation.activeTurn {
            return .stop(isEnabled: active.state == .running)
        }
        return .send(isEnabled: !isBrainRunActive && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var control: Control {
        Self.control(for: state.conversation, isBrainRunActive: isBrainRunActive, draft: draft)
    }

    private func send() {
        guard control == .send(isEnabled: true), onAsk(draft) else { return }
        draft = ""
    }
}

private struct BrainConversationTranscript: View {
    let conversation: BrainConversation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if conversation.turns.isEmpty {
                        ContentUnavailableView(
                            "Zeptejte se na své poznámky",
                            systemImage: "brain",
                            description: Text("Agent vychází z Brain Notes v _brain/ a podle potřeby čte uložené původní poznámky.")
                        )
                        .padding(.top, 40)
                    }
                    ForEach(conversation.turns) { turn in
                        BrainConversationTurnView(turn: turn)
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onChange(of: conversation.turns.last?.answer) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: conversation.turns.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

private struct BrainConversationTurnView: View {
    let turn: BrainConversation.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question)
                .font(.body.weight(.semibold))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if !turn.activity.isEmpty {
                DisclosureGroup("Činnost Agenta (\(turn.activity.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(turn.activity) { activity in
                            BrainConversationActivityRow(activity: activity)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !turn.answer.isEmpty {
                Text(Self.markdown(turn.answer))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            BrainConversationTurnStatus(turn: turn)
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
    }
}

private struct BrainConversationActivityRow: View {
    let activity: BrainConversation.Activity

    var body: some View {
        Label {
            Text(activity.title).lineLimit(2)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
    }

    private var icon: String {
        switch activity.kind {
        case .notice: return "info.circle"
        case .permission: return "checkmark.shield"
        case .tool(_, .pending), .tool(_, .inProgress): return "circle.dotted"
        case .tool(_, .completed): return "checkmark.circle"
        case .tool(_, .failed): return "xmark.circle"
        }
    }

    private var tint: Color {
        if case .tool(_, .failed) = activity.kind { return .red }
        return .secondary
    }
}

/// Elapsed time while the turn runs; afterwards how it ended. Errors and partial
/// answers never look like completed ones.
struct BrainConversationTurnStatus: View {
    let turn: BrainConversation.Turn

    enum Presentation: Equatable {
        case working(String)
        case completed(String)
        case incomplete(String)
        case failed(String)
    }

    static func presentation(of turn: BrainConversation.Turn, at now: Date) -> Presentation {
        switch turn.state {
        case .running:
            return .working("Agent pracuje… \(elapsed(from: turn.startedAt, to: now))")
        case .stopping:
            return .working("Zastavuji… \(elapsed(from: turn.startedAt, to: now))")
        case .completed:
            return .completed("Hotovo za \(elapsed(from: turn.startedAt, to: turn.finishedAt ?? turn.startedAt))")
        case .incomplete(let reason):
            return .incomplete("Neúplná odpověď: \(reason ?? "zastaveno")")
        case .failed(let message):
            return .failed(message)
        }
    }

    var body: some View {
        if turn.state.isActive {
            TimelineView(.periodic(from: turn.startedAt, by: 1)) { context in
                content(Self.presentation(of: turn, at: context.date))
            }
        } else {
            content(Self.presentation(of: turn, at: turn.finishedAt ?? turn.startedAt))
        }
    }

    @ViewBuilder
    private func content(_ presentation: Presentation) -> some View {
        switch presentation {
        case .working(let text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .completed(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .incomplete(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
