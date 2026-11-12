import AppKit
import QuickLookUI

/// Drives the shared Quick Look panel directly (SwiftUI's `quickLookPreview` wrapper
/// crashed opening the panel on macOS 27).
///
/// The panel is ordered front without becoming key, like Finder: the browser window
/// keeps focus, so arrow keys move the selection and Space closes the panel.
/// AppDelegate takes control of the panel through the responder chain and hands it
/// this object as data source and delegate.
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var url: URL?
    private var onClose: (() -> Void)?

    func show(_ url: URL, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.reloadData()
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func close() {
        url = nil
        onClose = nil
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }

    // MARK: QLPreviewPanelDelegate

    /// The panel's own close button (or Esc while it's key) clears the model's state.
    func windowWillClose(_ notification: Notification) {
        let onClose = self.onClose
        url = nil
        self.onClose = nil
        onClose?()
    }
}

extension AppDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate = QuickLookController.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}
