import Foundation
import NotessCore

/// Tag Groups (see `GLOSSARY.md`) in the Tags sidebar. They organise the
/// Tags of saved Daily Entries per Vault on this Mac and never change notes.
extension AppModel {
    /// The Tags sidebar's groups and All Tags, once the Tag list has loaded.
    var tagSidebar: TagSidebar? {
        guard case .loaded(let tags) = tagTimeline.tags else { return nil }
        return tagGroups.sidebar(vocabulary: tags)
    }

    /// Creates an empty group; nil if the name is unusable or nothing could be changed.
    @discardableResult
    func createTagGroup(named name: String) -> TagGroup.ID? {
        changeTagGroups { try $0.create(named: name) }
    }

    /// Creates a group that holds `tag`.
    @discardableResult
    func addTagToNewGroup(_ tag: String, named name: String) -> TagGroup.ID? {
        changeTagGroups { groups in
            let id = try groups.create(named: name)
            groups.add(tag: tag, to: id)
            return id
        }
    }

    func addTag(_ tag: String, toGroup id: TagGroup.ID) {
        changeTagGroups { $0.add(tag: tag, to: id) }
    }

    func removeTag(_ tag: String, fromGroup id: TagGroup.ID) {
        changeTagGroups { $0.remove(tag: tag, from: id) }
    }

    func deleteTagGroup(_ id: TagGroup.ID) {
        changeTagGroups { $0.delete(id) }
    }

    func setTagGroup(_ id: TagGroup.ID, isExpanded: Bool) {
        changeTagGroups { $0.setExpanded(isExpanded, for: id) }
    }

    /// Shows `vault`'s own Tag Groups; called whenever a Vault opens.
    func loadTagGroups(for vault: Vault) {
        do {
            tagGroups = try tagGroupStore.groups(for: vault)
            tagGroupsLoadFailure = nil
        } catch {
            tagGroups = TagGroups()
            let message = "Skupiny Tagů se nepodařilo načíst: \(error.localizedDescription)"
            tagGroupsLoadFailure = message
            errorMessage = message
        }
    }

    /// Applies `change` and remembers the result for the open Vault; a change
    /// that cannot be saved is reported and not shown, so the sidebar never
    /// shows groups that would be lost on the next launch.
    private func changeTagGroups<Result>(_ change: (inout TagGroups) throws -> Result) -> Result? {
        guard let vault else { return nil }
        if let tagGroupsLoadFailure {
            errorMessage = tagGroupsLoadFailure
            return nil
        }
        var groups = tagGroups
        let result: Result
        do {
            result = try change(&groups)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        guard groups != tagGroups else { return result }
        do {
            try tagGroupStore.remember(groups, for: vault)
        } catch {
            errorMessage = "Skupiny Tagů se nepodařilo uložit: \(error.localizedDescription)"
            return nil
        }
        tagGroups = groups
        return result
    }
}
