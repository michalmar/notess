import AppKit
import NotessCore
import SwiftUI

enum BrainConversationAnswer {
    static func attributedText(_ answer: String, palette: ThemePalette? = nil) -> AttributedString {
        var text = (try? AttributedString(
            markdown: BrainConversationEvidence.markdown(answer),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(answer)
        guard let palette else { return text }
        text.foregroundColor = Color(nsColor: palette.text)
        for run in text.runs {
            if let url = run.link {
                text[run.range].foregroundColor = Color(nsColor:
                    BrainConversationEvidence.noteLink(from: url) == nil ? palette.link : palette.wikiLink
                )
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                text[run.range].backgroundColor = Color(nsColor: palette.codeBackground)
            }
        }
        return text
    }
}

struct BrainConversationSources: View {
    let answer: String
    let onOpen: (URL) -> Void
    let category: (URL) -> String

    var body: some View {
        let sources = BrainConversationEvidence.sources(in: answer)
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Podklady odpovědi").font(.caption.weight(.semibold))
                ForEach(sources) { source in
                    BrainConversationSourceRow(source: source, onOpen: onOpen, category: category)
                }
            }
        }
    }
}

private struct BrainConversationSourceRow: View {
    let source: BrainConversationEvidence.Source
    let onOpen: (URL) -> Void
    let category: (URL) -> String
    @State private var categoryLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(categoryLabel).font(.caption).themedForeground(\.secondaryText, native: .secondary)
            BrainConversationSourceButton(source: source, onOpen: onOpen)
                .frame(height: 22)
        }
        // Resolve each new source once, not on every streamed answer character.
        .task(id: source.url) { categoryLabel = category(source.url) }
    }
}

/// Native link buttons provide keyboard activation, a full-target tooltip and
/// middle truncation for long Vault paths without widening the panel.
private struct BrainConversationSourceButton: NSViewRepresentable {
    let source: BrainConversationEvidence.Source
    let onOpen: (URL) -> Void
    @Environment(\.themePalette) private var palette

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func open() { action() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator { onOpen(source.url) }
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: source.label, target: context.coordinator, action: #selector(Coordinator.open))
        button.isBordered = false
        button.alignment = .left
        button.lineBreakMode = .byTruncatingMiddle
        button.font = .preferredFont(forTextStyle: .body)
        button.contentTintColor = .linkColor
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = source.label
        button.contentTintColor = palette.map {
            BrainConversationEvidence.noteLink(from: source.url) == nil ? $0.link : $0.wikiLink
        } ?? .linkColor
        button.toolTip = source.url.absoluteString
        button.identifier = NSUserInterfaceItemIdentifier("brain-source:\(source.url.absoluteString)")
        button.setAccessibilityLabel("Otevřít zdroj \(source.label)")
        context.coordinator.action = { onOpen(source.url) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 22)
    }
}
