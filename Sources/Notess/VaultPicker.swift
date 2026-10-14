import AppKit

@MainActor
enum VaultPicker {
    /// Asks the user for the Vault folder; nil if cancelled.
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Vyberte složku Vaultu"
        panel.message = "Vault je složka, ve které Notess ukládá všechny poznámky jako Markdown soubory."
        panel.prompt = "Použít jako Vault"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
