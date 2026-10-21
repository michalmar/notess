import Foundation

/// A Tag Group (see `GLOSSARY.md`): a flat, named collection of normalised
/// Tags in the Tags sidebar. It only organises Tags: it never changes notes,
/// files or what a Tag means, and it has no subgroups.
public struct TagGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// Normalised Tag names, alphabetically; kept even while no saved Daily
    /// Entry carries the Tag, so the Tag reappears here when it returns.
    public var tags: [String]
    /// Whether the sidebar shows the group's Tags or only its name.
    public var isExpanded: Bool

    public init(id: UUID = UUID(), name: String, tags: [String] = [], isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.tags = tags
        self.isExpanded = isExpanded
    }
}

public enum TagGroupError: Error, LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "Skupina Tagů musí mít název."
        case .duplicateName(let name):
            "Skupina Tagů „\(name)“ už existuje."
        }
    }
}

/// A Vault's Tag Groups. Every change affects only the named group or
/// membership; Tags themselves come from saved Daily Entries.
public struct TagGroups: Codable, Equatable, Sendable {
    /// The groups, alphabetically by name.
    public private(set) var groups: [TagGroup]

    public init(groups: [TagGroup] = []) {
        self.groups = groups.sorted(by: Self.sortsBefore)
    }

    /// Adds an empty group; the name is trimmed and must be new, ignoring case.
    @discardableResult
    public mutating func create(named name: String) throws -> TagGroup.ID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagGroupError.emptyName }
        let key = Self.nameKey(trimmed)
        guard !groups.contains(where: { Self.nameKey($0.name) == key }) else {
            throw TagGroupError.duplicateName(trimmed)
        }
        let group = TagGroup(name: trimmed)
        groups.append(group)
        groups.sort(by: Self.sortsBefore)
        return group.id
    }

    /// Adds `tag` (with or without `#`, any case) to one group, keeping every
    /// other membership.
    public mutating func add(tag: String, to id: TagGroup.ID) {
        let normalized = Tag.normalize(tag)
        guard !normalized.isEmpty, let index = groups.firstIndex(where: { $0.id == id }),
              !groups[index].tags.contains(normalized) else { return }
        groups[index].tags.append(normalized)
        groups[index].tags.sort(by: Self.tagSortsBefore)
    }

    /// Removes `tag` from one group only.
    public mutating func remove(tag: String, from id: TagGroup.ID) {
        let normalized = Tag.normalize(tag)
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].tags.removeAll { $0 == normalized }
    }

    /// Deletes one group and its memberships; Tags and other groups stay.
    public mutating func delete(_ id: TagGroup.ID) {
        groups.removeAll { $0.id == id }
    }

    public mutating func setExpanded(_ isExpanded: Bool, for id: TagGroup.ID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isExpanded = isExpanded
    }

    /// What the Tags sidebar shows for `vocabulary`, the normalised Tags of
    /// saved Daily Entries: every group (empty ones too) with only its Tags in
    /// the vocabulary, and All Tags with each Tag once.
    public func sidebar(vocabulary: [String]) -> TagSidebar {
        var seen = Set<String>()
        let allTags = vocabulary.filter { seen.insert($0).inserted }
        return TagSidebar(
            groups: groups.map { group in
                TagSidebar.Group(
                    id: group.id,
                    name: group.name,
                    isExpanded: group.isExpanded,
                    tags: group.tags.filter(seen.contains)
                )
            },
            allTags: allTags
        )
    }

    private static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func sortsBefore(_ lhs: TagGroup, _ rhs: TagGroup) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func tagSortsBefore(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

/// The Tags sidebar's organisation: Tag Groups above the complete All Tags list.
public struct TagSidebar: Equatable, Sendable {
    public struct Group: Equatable, Identifiable, Sendable {
        public let id: TagGroup.ID
        public let name: String
        public let isExpanded: Bool
        /// The group's Tags that saved Daily Entries currently carry.
        public let tags: [String]
    }

    public let groups: [Group]
    /// Every Tag of saved Daily Entries once, grouped or not.
    public let allTags: [String]
}
