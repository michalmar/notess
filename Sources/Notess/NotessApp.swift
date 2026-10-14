import AppKit
import NotessCore
import SwiftUI

@main
struct NotessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Notess", id: "main") {
            RootView(
                model: appDelegate.model,
                onCloseTab: appDelegate.closeTab
            )
                .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 820, height: 640)
        Settings {
            SettingsView(model: appDelegate.model)
        }
        .commands {
            NoteCommands(
                model: appDelegate.model,
                onCloseActiveTab: appDelegate.closeActiveTab
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var closeTabEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`), harmless in the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        closeTabEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "w",
                  NSApp.modalWindow == nil,
                  self?.model.document != nil else { return event }
            self?.closeActiveTab()
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasUnsavedChanges else { return .terminateNow }
        switch saveDecision(
            message: "Uložit všechny změny?",
            informativeText: "Některé otevřené poznámky obsahují neuložené změny.",
            saveTitle: "Uložit vše",
            discardTitle: "Zahodit"
        ) {
        case .save:
            if model.saveAll() { return .terminateNow }
            showSaveError()
            return .terminateCancel
        case .discard:
            return .terminateNow
        case .cancel:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let closeTabEventMonitor {
            NSEvent.removeMonitor(closeTabEventMonitor)
        }
    }

    func closeActiveTab() {
        guard let document = model.document else { return }
        closeTab(documentID: document.id)
    }

    func closeTab(documentID: NoteDocument.ID) {
        guard let document = model.tabSession.documents.first(where: {
            $0.id == documentID
        }) else { return }
        guard document.hasUnsavedChanges else {
            model.closeTab(documentID: documentID)
            return
        }

        switch saveDecision(
            message: "Uložit změny?",
            informativeText: "\(document.fileURL.lastPathComponent) obsahuje neuložené změny.",
            saveTitle: "Uložit",
            discardTitle: "Neukládat"
        ) {
        case .save:
            guard model.save(documentID: documentID) else {
                showSaveError()
                return
            }
            model.closeTab(documentID: documentID)
        case .discard:
            model.closeTab(documentID: documentID)
        case .cancel:
            break
        }
    }

    private func saveDecision(
        message: String,
        informativeText: String,
        saveTitle: String,
        discardTitle: String
    ) -> SaveDecision {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: saveTitle)
        alert.addButton(withTitle: discardTitle)
        alert.addButton(withTitle: "Zrušit")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private func showSaveError() {
        let alert = NSAlert()
        alert.messageText = model.errorMessage ?? "Uložení se nezdařilo."
        model.errorMessage = nil
        alert.runModal()
    }
}

private enum SaveDecision {
    case save
    case discard
    case cancel
}
