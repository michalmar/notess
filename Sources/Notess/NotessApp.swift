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
        let alert = NSAlert()
        alert.messageText = "Uložit všechny změny?"
        alert.informativeText = "Některé otevřené poznámky obsahují neuložené změny."
        alert.addButton(withTitle: "Uložit vše")
        alert.addButton(withTitle: "Zahodit")
        alert.addButton(withTitle: "Zrušit")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if model.saveAll() { return .terminateNow }
            showSaveError()
            return .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
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

        let alert = NSAlert()
        alert.messageText = "Uložit změny?"
        alert.informativeText = "\(document.fileURL.lastPathComponent) obsahuje neuložené změny."
        alert.addButton(withTitle: "Uložit")
        alert.addButton(withTitle: "Neukládat")
        alert.addButton(withTitle: "Zrušit")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard model.save(documentID: documentID) else {
                showSaveError()
                return
            }
            model.closeTab(documentID: documentID)
        case .alertSecondButtonReturn:
            model.closeTab(documentID: documentID)
        default:
            break
        }
    }

    private func showSaveError() {
        let alert = NSAlert()
        alert.messageText = model.errorMessage ?? "Uložení se nezdařilo."
        model.errorMessage = nil
        alert.runModal()
    }
}
