import Foundation

/// One Section of a Tag Timeline (see `GLOSSARY.md`): its complete saved
/// Markdown and where it comes from.
public struct TagTimelineSection: Hashable, Sendable, Identifiable {
    /// The Daily Entry's Vault-relative path.
    public let relativePath: String
    /// The Section's position in the note (`SearchSection.ordinal`).
    public let ordinal: Int
    /// The Section heading (`SearchSection.title`), used with `ordinal` to
    /// find the Section again in the note's current text (`SearchSection.locate`).
    public let title: String?
    /// The whole Section as saved, heading, deeper headings and image Markdown included.
    public let markdown: String

    public var id: String { "\(relativePath)#\(ordinal)" }

    public init(relativePath: String, ordinal: Int, title: String?, markdown: String) {
        self.relativePath = relativePath
        self.ordinal = ordinal
        self.title = title
        self.markdown = markdown
    }
}

/// The Sections of one Daily Entry in a Tag Timeline, in their order in the note.
public struct TagTimelineDay: Hashable, Sendable, Identifiable {
    public let day: Day
    public let sections: [TagTimelineSection]

    public var id: Day { day }

    public init(day: Day, sections: [TagTimelineSection]) {
        self.day = day
        self.sections = sections
    }
}
