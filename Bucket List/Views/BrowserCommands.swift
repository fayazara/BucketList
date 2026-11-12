import AppKit
import SwiftUI

extension FocusedValues {
    /// The browser in the key window, for menu commands.
    @Entry var browser: BrowserModel?
}

/// File and Go menu items, like Finder's. They act on the browser in the key window.
struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { browser?.requestNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser == nil)
            Button("Upload…") { browser?.isImporting = true }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(browser == nil)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open") { if let browser { browser.activate(browser.selection) } }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(browser?.selection.isEmpty ?? true)
            Button("Quick Look") { browser?.togglePreview() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!(browser?.canQuickLook ?? false))
            Button("Download") { if let browser { browser.download(browser.selectedItems) } }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(browser?.selection.isEmpty ?? true)
            Divider()
            Button("Delete…") { browser?.requestDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(browser?.selection.isEmpty ?? true)
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh") { browser?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(browser == nil)
        }
        CommandMenu("Go") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(browser?.backStack.isEmpty ?? true)
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(browser?.forwardStack.isEmpty ?? true)
            Button("Enclosing Folder") { browser?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(browser?.prefix.isEmpty ?? true)
        }
    }
}

/// Space toggles Quick Look anywhere in the browser window, like Finder.
///
/// A window-level key monitor rather than `onKeyPress`, because the table and grid
/// each grab keys differently. It leaves Space alone while typing (search field),
/// while a sheet is up, and when another window such as the Quick Look panel is key.
@MainActor
final class SpaceKeyMonitor {
    weak var window: NSWindow?
    private var monitor: Any?

    func start(_ action: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 49, !event.isARepeat,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = self.window, NSApp.keyWindow === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSText)
            else { return event }
            action()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Hands back the NSWindow hosting a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}
