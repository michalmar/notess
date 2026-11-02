import AppKit
import NotessEditor

/// Native responder items keep availability tied to the focused editor and
/// its current selection, rather than the app's active document alone.
@MainActor
final class SourceLineMenuController {
    private var observers: [NSObjectProtocol] = []
    private var installationScheduled = false

    func start() {
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleInstallation() }
            })
        }
        Self.install(in: NSApp.mainMenu)
        scheduleInstallation()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func scheduleInstallation() {
        guard !installationScheduled else { return }
        installationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.installationScheduled = false
            Self.install(in: NSApp.mainMenu)
        }
    }

    static func install(in mainMenu: NSMenu?) {
        guard let edit = mainMenu?.items.compactMap(\.submenu).first(where: {
            $0.items.contains { $0.action == #selector(NSText.copy(_:)) }
        }), !edit.items.contains(where: { $0.action == SourceLineCommand.all.first?.action }) else { return }
        edit.addItem(.separator())
        for command in SourceLineCommand.all { edit.addItem(command.makeMenuItem()) }
    }
}
