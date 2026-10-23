import Foundation
import NotessCore

extension AppModel {
    /// Follows answer evidence without saving, reloading or hiding the conversation.
    func openBrainConversationSource(
        _ url: URL,
        openWeb: @MainActor (URL) -> Bool = SystemWebLinkOpener.open
    ) {
        if BrainConversationEvidence.isWebURL(url) {
            if !openWeb(url) {
                errorMessage = "Webový zdroj se nepodařilo otevřít: \(url.absoluteString)"
            }
        } else if let link = BrainConversationEvidence.noteLink(from: url) {
            openWikiLink(link)
        } else {
            errorMessage = "Neplatný nebo nepodporovaný zdroj: \(url.absoluteString)"
        }
    }

    /// Classify the resolved note, not an Agent-provided label or an ambiguous name.
    func brainConversationSourceCategory(_ url: URL) -> String {
        if BrainConversationEvidence.isWebURL(url) { return "Externí zdroj" }
        guard let link = BrainConversationEvidence.noteLink(from: url), let vault else {
            return "Neplatný zdroj"
        }
        let paths = vault.scanNotePaths() + tabSession.restorationState(relativeTo: vault.rootURL).relativePaths
        guard let path = WikiLinkResolver(relativePaths: paths).resolve(target: link.target),
              let kind = NoteKind.classify(relativePath: path)
        else { return "Nenalezená poznámka" }
        switch kind {
        case .brainNote: return "Brain Note"
        case .dailyEntry: return "Původní poznámka · Daily Entry"
        case .freeNote: return "Původní poznámka · Free Note"
        }
    }
}
