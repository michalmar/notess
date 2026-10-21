import Foundation
import NotessCore

enum NoteDeletionConfirmationKind: Equatable {
    case savedFile
    case dirtyFile
    case draftDailyEntry
}

enum NoteDeletionChoice {
    case moveToTrash
    case saveAndMoveToTrash
    case discardChangesAndMoveToTrash
    case discardDraft
}

struct NoteDeletionConfirmation: Equatable {
    let relativePath: String
    let kind: NoteDeletionConfirmationKind

    var displayName: String {
        URL(filePath: relativePath).deletingPathExtension().lastPathComponent
    }
}

extension AppModel {
    func cancelNoteDeletion() {
        noteDeletionConfirmation = nil
    }

    func canDeleteNote(relativePath: String) -> Bool {
        guard let vault, !relativePath.hasPrefix("/"),
              relativePath.split(separator: "/").first != Substring(NoteKind.brainFolder),
              let kind = NoteKind.classify(relativePath: relativePath),
              kind == .freeNote || kind == .dailyEntry else { return false }
        let fileURL = vault.rootURL.appending(path: relativePath, directoryHint: .notDirectory)
        guard vault.contains(fileURL) else { return false }
        if FileManager.default.fileExists(atPath: fileURL.path) { return true }
        return kind == .dailyEntry && tabSession.document(at: fileURL)?.existsOnDisk == false
    }

    func requestNoteDeletion(relativePath: String) {
        guard canDeleteNote(relativePath: relativePath), let vault,
              let kind = NoteKind.classify(relativePath: relativePath) else { return }
        let fileURL = vault.rootURL.appending(path: relativePath, directoryHint: .notDirectory)
        let document = tabSession.document(at: fileURL)
        if kind == .dailyEntry, let document, !document.existsOnDisk {
            noteDeletionConfirmation = NoteDeletionConfirmation(
                relativePath: relativePath,
                kind: .draftDailyEntry
            )
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        document?.reconcileWithDisk()
        noteDeletionConfirmation = NoteDeletionConfirmation(
            relativePath: relativePath,
            kind: document?.hasUnsavedChanges == true ? .dirtyFile : .savedFile
        )
    }

    func confirmNoteDeletion(_ choice: NoteDeletionChoice) {
        guard let confirmation = noteDeletionConfirmation,
              let vault else { return }
        let fileURL = vault.rootURL.appending(
            path: confirmation.relativePath,
            directoryHint: .notDirectory
        )
        let document = tabSession.document(at: fileURL)
        switch choice {
        case .discardDraft:
            guard confirmation.kind == .draftDailyEntry, let document else { return }
            noteDeletionConfirmation = nil
            closeTab(documentID: document.id)
            return
        case .moveToTrash:
            guard confirmation.kind == .savedFile else { return }
            if document?.hasUnsavedChanges == true {
                requestNoteDeletion(relativePath: confirmation.relativePath)
                return
            }
            noteDeletionConfirmation = nil
        case .saveAndMoveToTrash:
            guard confirmation.kind == .dirtyFile else { return }
            noteDeletionConfirmation = nil
            guard let document, save(documentID: document.id) else { return }
        case .discardChangesAndMoveToTrash:
            guard confirmation.kind == .dirtyFile, document != nil else { return }
            noteDeletionConfirmation = nil
        }
        do {
            try moveToTrash(fileURL)
        } catch {
            errorMessage = "Poznámku se nepodařilo přesunout do Koše: \(error.localizedDescription)"
            return
        }
        if let document {
            closeTab(documentID: document.id)
        }
        refreshTree()
        handleVaultChange(VaultChange(relativePaths: [confirmation.relativePath]))
    }
}
