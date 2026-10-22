import NotessCore

extension AppModel {
    /// Shows the Tag Timeline of a Tag clicked in a note: Tags mode with the
    /// normalised Tag selected, exactly as if it were picked in the Tags
    /// sidebar. Tabs and documents are left as they are and nothing is saved
    /// (ADR 0003), so switching back to Journal shows the note unchanged.
    func openTagTimeline(_ tag: String) {
        sidebarMode = .tags
        selectTimelineTag(Tag.normalize(tag))
    }
}
