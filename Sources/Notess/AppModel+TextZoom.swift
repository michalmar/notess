import Foundation
import NotessCore

/// Note text zoom commands, shared by the View menu, the keyboard shortcuts and
/// the editor toolbar. The zoom itself lives in `AppSettings`.
extension AppModel {
    /// True while zoom commands may act on the displayed note: the main note
    /// window is key, a note is shown in the editor, and nothing covers it.
    var isTextZoomRoutable: Bool {
        isNoteWindowKey
            && document != nil
            && sidebarMode == .journal
            && imagePreview.content == nil
            && !isQuickOpenPresented
            && !isSearchPresented
    }

    var canZoomInText: Bool { isTextZoomRoutable && settings.canZoomIn }
    var canZoomOutText: Bool { isTextZoomRoutable && settings.canZoomOut }

    func zoomInText() {
        guard canZoomInText else { return }
        settings.zoomIn()
    }

    func zoomOutText() {
        guard canZoomOutText else { return }
        settings.zoomOut()
    }

    func resetTextZoom() {
        guard isTextZoomRoutable else { return }
        settings.resetTextZoom()
    }
}
