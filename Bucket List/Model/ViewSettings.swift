import SwiftUI

enum ViewMode: String, CaseIterable {
    case icons, list
}

/// Zoom steps for ⌘+ / ⌘−, stored per view mode in UserDefaults.
enum Zoom {
    static let listIconSizes: [CGFloat] = [16, 20, 24, 32, 48]
    static let gridIconSizes: [CGFloat] = [48, 64, 80, 96, 128, 160, 200]
    static let defaultList = 0
    static let defaultGrid = 3

    static func listSize(_ level: Int) -> CGFloat { listIconSizes[clamp(level, listIconSizes)] }
    static func gridSize(_ level: Int) -> CGFloat { gridIconSizes[clamp(level, gridIconSizes)] }

    static func step(_ level: Int, by delta: Int, mode: ViewMode) -> Int {
        let sizes = mode == .list ? listIconSizes : gridIconSizes
        return clamp(level + delta, sizes)
    }

    private static func clamp(_ level: Int, _ sizes: [CGFloat]) -> Int {
        min(max(level, 0), sizes.count - 1)
    }
}

enum SettingsKey {
    static let viewMode = "viewMode"
    static let listZoom = "listZoom"
    static let gridZoom = "gridZoom"
    static let quickUploadAccount = "quickUpload.account"
    static let quickUploadBucket = "quickUpload.bucket"
    static let quickUploadPrefix = "quickUpload.prefix"
    static let quickUploadPreferPublic = "quickUpload.preferPublic"
}

/// View menu items, mirroring Finder's shortcuts.
struct ViewCommands: Commands {
    @AppStorage(SettingsKey.viewMode) private var mode: ViewMode = .list
    @AppStorage(SettingsKey.listZoom) private var listZoom = Zoom.defaultList
    @AppStorage(SettingsKey.gridZoom) private var gridZoom = Zoom.defaultGrid

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Picker("View", selection: $mode) {
                Text("as Icons").tag(ViewMode.icons).keyboardShortcut("1", modifiers: .command)
                Text("as List").tag(ViewMode.list).keyboardShortcut("2", modifiers: .command)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()
            Button("Make Bigger") { zoom(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Make Smaller") { zoom(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") {
                if mode == .list { listZoom = Zoom.defaultList } else { gridZoom = Zoom.defaultGrid }
            }
            .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }

    private func zoom(by delta: Int) {
        if mode == .list {
            listZoom = Zoom.step(listZoom, by: delta, mode: .list)
        } else {
            gridZoom = Zoom.step(gridZoom, by: delta, mode: .icons)
        }
    }
}
