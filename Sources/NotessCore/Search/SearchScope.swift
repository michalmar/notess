import Foundation

/// Which part of the Vault global search covers: everything, or only the
/// Journal (Daily Entries), Notes (Free Notes) or Brain (Brain Notes).
public enum SearchScope: String, CaseIterable, Hashable, Sendable {
    case all
    case journal
    case notes
    case brain

    /// The note kinds searched, in result group order Journal, Notes, Brain.
    public var kinds: [NoteKind] {
        switch self {
        case .all: NoteKind.searchOrder
        case .journal: [.dailyEntry]
        case .notes: [.freeNote]
        case .brain: [.brainNote]
        }
    }
}
