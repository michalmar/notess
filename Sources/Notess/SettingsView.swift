import NotessCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var vaultToOpen: URL?
    @State private var autodetectedCLIPath: URL?

    var body: some View {
        Form {
            Section("Vault") {
                LabeledContent("Aktuální Vault") {
                    Text(model.vault?.rootURL.path(percentEncoded: false) ?? "Nevybrán")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Změnit Vault…") {
                    guard let url = VaultPicker.chooseFolder() else { return }
                    requestVaultChange(to: url)
                }
            }

            Section("Editor") {
                TextField(
                    "Písmo",
                    text: Binding(
                        get: { model.settings.editorFont.name },
                        set: { model.settings.editorFont.name = $0.isEmpty ? EditorFont.default.name : $0 }
                    )
                )
                HStack {
                    Text("Velikost")
                    Spacer()
                    TextField(
                        "Velikost písma",
                        value: Binding(
                            get: { model.settings.editorFont.size },
                            set: { model.settings.editorFont.size = min(max($0, 8), 72) }
                        ),
                        format: .number.precision(.fractionLength(0))
                    )
                    .frame(width: 48)
                    Stepper(
                        "Velikost písma",
                        value: Binding(
                            get: { model.settings.editorFont.size },
                            set: { model.settings.editorFont.size = $0 }
                        ),
                        in: 8...72,
                        step: 1
                    )
                    .labelsHidden()
                }
            }

            Section("Vzhled") {
                LabeledContent("Téma") {
                    Text("Podle systému")
                }
                Text("Notess automaticky sleduje světlý a tmavý vzhled macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Copilot CLI") {
                TextField(
                    "Cesta",
                    text: Binding(
                        get: { model.settings.copilotCLIPath ?? "" },
                        set: { model.settings.copilotCLIPath = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text(autodetectedCLIPath?.path(percentEncoded: false) ?? "Autodetekovat")
                )
                HStack {
                    cliStatus
                    Spacer()
                    if model.settings.copilotCLIPath != nil {
                        Button("Použít autodetekci") {
                            model.settings.useAutodetectedCopilotCLI()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 500)
        .task {
            autodetectedCLIPath = await Task.detached(priority: .utility) {
                CopilotCLILocator().detect()
            }.value
        }
        .alert(
            "Uložit změny před změnou Vaultu?",
            isPresented: Binding(
                get: { vaultToOpen != nil && model.hasUnsavedChanges },
                set: { if !$0 { vaultToOpen = nil } }
            ),
            actions: {
                Button("Uložit a změnit") {
                    if model.saveAll() { openRequestedVault() }
                }
                Button("Zahodit změny", role: .destructive) {
                    openRequestedVault()
                }
                Button("Zrušit", role: .cancel) {
                    vaultToOpen = nil
                }
            },
            message: {
                Text("Některé otevřené poznámky obsahují neuložené změny.")
            }
        )
    }

    @ViewBuilder
    private var cliStatus: some View {
        if let configuredPath = model.settings.copilotCLIPath {
            let exists = FileManager.default.isExecutableFile(atPath: configuredPath)
            Label(
                exists ? "Nastavená cesta je dostupná" : "Copilot CLI na zadané cestě nebyl nalezen",
                systemImage: exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(exists ? .green : .red)
        } else if let autodetectedCLIPath {
            Label(
                "Nalezeno: \(autodetectedCLIPath.path(percentEncoded: false))",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        } else {
            Label("Copilot CLI nebyl nalezen", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func requestVaultChange(to url: URL) {
        vaultToOpen = url
        if !model.hasUnsavedChanges {
            openRequestedVault()
        }
    }

    private func openRequestedVault() {
        guard let vaultToOpen else { return }
        model.chooseVault(at: vaultToOpen)
        self.vaultToOpen = nil
    }
}
