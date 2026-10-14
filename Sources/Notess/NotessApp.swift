import AppKit
import SwiftUI

@main
struct NotessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Notess", id: "main") {
            RootView(model: appDelegate.model)
                .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 820, height: 640)
        Settings {
            SettingsView(model: appDelegate.model)
        }
        .commands {
            NoteCommands(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here so the quit guard below can reach it.
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`), harmless in the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Minimal ADR 0003 guard so quitting (or closing the last window) never drops
    /// unsaved text silently. Issue #3 replaces it with per-tab prompts.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Uložit změny?"
        alert.informativeText = "Dnešní záznam obsahuje neuložené změny."
        alert.addButton(withTitle: "Uložit")
        alert.addButton(withTitle: "Neukládat")
        alert.addButton(withTitle: "Zrušit")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if model.save() { return .terminateNow }
            showSaveError()
            return .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func showSaveError() {
        let alert = NSAlert()
        alert.messageText = model.errorMessage ?? "Uložení se nezdařilo."
        model.errorMessage = nil
        alert.runModal()
    }
}
