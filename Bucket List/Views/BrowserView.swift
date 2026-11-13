import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    let model: BrowserModel
    @AppStorage(SettingsKey.viewMode) private var mode: ViewMode = .list
    @AppStorage(SettingsKey.listZoom) private var listZoom = Zoom.defaultList
    @AppStorage(SettingsKey.gridZoom) private var gridZoom = Zoom.defaultGrid
    @State private var isDropTargeted = false
    @State private var spaceKey = SpaceKeyMonitor()

    var body: some View {
        @Bindable var model = model
        content
            .overlay { overlay }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3).padding(2)
                }
            }
            .overlay(alignment: .bottom) {
                if let progress = model.previewProgress {
                    PreviewProgress(fraction: progress) { model.closePreview() }
                        .padding(.bottom, 16)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { PathBar(model: model) }
            .sheet(item: $model.infoItem) { item in
                InfoPreview(model: model, item: item)
            }
            .onChange(of: model.selection) { model.selectionChanged() }
            .onChange(of: model.quickLookURL) { _, url in
                if let url {
                    QuickLookController.shared.show(url) { model.quickLookURL = nil }
                } else {
                    QuickLookController.shared.close()
                }
            }
            .onDisappear { model.closePreview() }
            .focusedSceneValue(\.browser, model)
            .background(WindowReader { spaceKey.window = $0 })
            .onDisappear { spaceKey.stop() }
            .navigationTitle(model.title)
            .toolbar { toolbar }
            .searchable(text: $model.query, placement: .toolbar, prompt: "Search this folder")
            .task(id: model.bucket) {
                // Re-run per bucket so the key monitor and poller act on the current model.
                let model = model
                spaceKey.start { model.togglePreview() }
                model.refreshIfStale()
                await poll(model)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshIfStale()
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.upload(urls)
                return !urls.isEmpty
            } isTargeted: { isDropTargeted = $0 }
            .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.upload(urls) }
            }
            .alert("New Folder", isPresented: $model.isNamingFolder) {
                TextField("Name", text: $model.folderName)
                Button("Create") {
                    let name = model.folderName
                    Task { await model.createFolder(named: name) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                deleteTitle,
                isPresented: Binding(get: { !model.pendingDelete.isEmpty }, set: { if !$0 { model.pendingDelete = [] } })
            ) {
                Button("Delete", role: .destructive) {
                    let targets = model.pendingDelete
                    Task { await model.delete(targets) }
                }
            } message: {
                Text(model.pendingDelete.contains(where: \.isFolder)
                     ? "Folders are deleted with everything inside them. This can't be undone."
                     : "This can't be undone.")
            }
            .confirmationDialog(
                "Make “\(model.bucket.name)” public?",
                isPresented: Binding(get: { model.pendingPublicLink != nil }, set: { if !$0 { model.pendingPublicLink = nil } })
            ) {
                Button("Enable r2.dev Public Access") { Task { await model.enablePublicAccessAndCopy() } }
                Button("Copy Private Link (7 Days)") {
                    let files = model.pendingPublicLink ?? []
                    model.pendingPublicLink = nil
                    Task { await model.copyPrivateLinks(files, expires: 604_800) }
                }
                Button("Cancel", role: .cancel) { model.pendingPublicLink = nil }
            } message: {
                Text("This bucket has no public domain. Turning on r2.dev access lets anyone with a link read every file in the bucket. Cloudflare rate-limits r2.dev, so use a custom domain for production traffic.")
            }
    }

    /// Visible-folder refresh every 60 s while the app is frontmost.
    private func poll(_ model: BrowserModel) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if NSApp.isActive { model.refreshIfStale() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .list:
            ListBrowser(model: model, iconSize: Zoom.listSize(listZoom), menu: menu)
        case .icons:
            IconBrowser(model: model, iconSize: Zoom.gridSize(gridZoom), menu: menu)
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func menu(for items: [BrowserItem]) -> some View {
        if items.isEmpty {
            Button("New Folder") { model.requestNewFolder() }
            Button("Upload…") { model.isImporting = true }
            Divider()
            Button("Refresh") { model.reload() }
        } else {
            if items.count == 1, let folder = items.first, folder.isFolder {
                Button("Open") { model.open(prefix: folder.id) }
                Divider()
            }
            if let file = items.first(where: { !$0.isFolder }) {
                Button("Quick Look “\(file.name)”") { model.preview(file) }
            }
            Button("Download") { model.download(items) }
            if items.contains(where: { !$0.isFolder }) {
                Divider()
                Button("Copy Public Link") { Task { await model.copyPublicLinks(items) } }
                privateLinkMenu(items)
            }
            Divider()
            Button("Delete…", role: .destructive) { model.requestDelete(items) }
        }
    }

    private func privateLinkMenu(_ items: [BrowserItem]) -> some View {
        Menu("Copy Private Link") {
            Button("Expires in 1 Hour") { Task { await model.copyPrivateLinks(items, expires: 3600) } }
            Button("Expires in 1 Day") { Task { await model.copyPrivateLinks(items, expires: 86_400) } }
            Button("Expires in 7 Days") { Task { await model.copyPrivateLinks(items, expires: 604_800) } }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button("Back", systemImage: "chevron.left") { model.goBack() }
                    .disabled(model.backStack.isEmpty)
                    .help("See folders you viewed previously")
                Button("Forward", systemImage: "chevron.right") { model.goForward() }
                    .disabled(model.forwardStack.isEmpty)
                    .help("See folders you viewed next")
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $mode) {
                Label("Icons", systemImage: "square.grid.2x2").tag(ViewMode.icons)
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Change the item arrangement")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Upload", systemImage: "square.and.arrow.up") { model.isImporting = true }
                .help("Upload files")
            Menu("Actions", systemImage: "ellipsis.circle") {
                menu(for: model.selectedItems)
                if !model.selectedItems.isEmpty {
                    Divider()
                    Button("New Folder") { model.requestNewFolder() }
                    Button("Refresh") { model.reload() }
                }
            }
            .help("Actions for the selected items")
            TransfersButton(app: model.app)
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if let error = model.error {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        } else if model.items.isEmpty && model.isLoading {
            ProgressView()
        } else if model.items.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder",
                                   description: Text("Drop files here to upload them."))
        } else if model.visibleItems.isEmpty {
            ContentUnavailableView.search(text: model.query)
        }
    }

    private var deleteTitle: String {
        model.pendingDelete.count == 1
            ? "Delete “\(model.pendingDelete[0].name)”?"
            : "Delete \(model.pendingDelete.count) items?"
    }
}

// MARK: - List

private struct ListBrowser<Menu: View>: View {
    @Bindable var model: BrowserModel
    let iconSize: CGFloat
    let menu: ([BrowserItem]) -> Menu

    var body: some View {
        Table(model.visibleItems, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    ItemIcon(app: model.app, bucket: model.bucket, item: item, size: iconSize, thumbnails: iconSize >= 32)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, iconSize > 16 ? 2 : 0)
                .onAppear {
                    if item.id == model.visibleItems.last?.id { model.loadMore() }
                }
            }
            .width(min: 220, ideal: 420)

            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.isFolder ? "--" : FinderDate.string(item.modified))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "--" : item.size.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .background(FinderTableHeader())
        .contextMenu(forSelectionType: BrowserItem.ID.self) { ids in
            menu(model.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            model.activate(ids)
        }
    }
}

// MARK: - Icons

private struct IconBrowser<Menu: View>: View {
    @Bindable var model: BrowserModel
    let iconSize: CGFloat
    let menu: ([BrowserItem]) -> Menu
    @State private var anchor: BrowserItem.ID?
    @FocusState private var focused: Bool

    private var cellWidth: CGFloat { max(iconSize + 24, 96) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: 6)], spacing: 10) {
                ForEach(model.visibleItems) { item in
                    IconCell(app: model.app, bucket: model.bucket, item: item, size: iconSize, width: cellWidth,
                             isSelected: model.selection.contains(item.id))
                        .onTapGesture(count: 2) { model.activate([item.id]) }
                        .simultaneousGesture(TapGesture().onEnded { click(item) })
                        .contextMenu {
                            menu(model.selection.contains(item.id) ? model.selectedItems : [item])
                        }
                        .onAppear {
                            if item.id == model.visibleItems.last?.id { model.loadMore() }
                        }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background {
            Color(nsColor: .textBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture { model.selection = []; focused = true }
                .contextMenu { menu([]) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.return) {
            guard !model.selection.isEmpty else { return .ignored }
            model.activate(model.selection)
            return .handled
        }
    }

    /// Finder-style selection: click, ⌘-click to toggle, ⇧-click for a range.
    private func click(_ item: BrowserItem) {
        focused = true
        let flags = NSEvent.modifierFlags
        let ids = model.visibleItems.map(\.id)
        if flags.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
            anchor = item.id
        } else if flags.contains(.shift), let anchor, let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: item.id) {
            model.selection = Set(ids[min(a, b)...max(a, b)])
        } else {
            model.selection = [item.id]
            anchor = item.id
        }
    }
}

private struct IconCell: View {
    let app: AppModel
    let bucket: BucketRef
    let item: BrowserItem
    let size: CGFloat
    let width: CGFloat
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ItemIcon(app: app, bucket: bucket, item: item, size: size, thumbnails: true)
                .padding(4)
                .background(isSelected ? Color.secondary.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
            Text(item.name)
                .font(size >= 96 ? .body : .callout)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? Color.white : .primary)
                .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

// MARK: - Shared pieces

/// File-type icon, replaced by an image thumbnail once one is available.
struct ItemIcon: View {
    // Passed in, not read from the environment: Table cells are separately hosted
    // and can lay out before the environment reaches them.
    let app: AppModel
    let bucket: BucketRef
    let item: BrowserItem
    let size: CGFloat
    var thumbnails = true
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: max(2, size / 24)))
                    .shadow(color: .black.opacity(0.15), radius: size > 32 ? 1 : 0, y: 0.5)
            } else {
                Image(nsImage: Icons.icon(for: item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: wantsThumbnail ? item.id + (item.etag ?? "") : nil) {
            guard wantsThumbnail else { thumbnail = nil; return }
            thumbnail = Thumbnails.shared.cached(bucket, item)
            if thumbnail == nil {
                thumbnail = await Thumbnails.shared.thumbnail(bucket, item, app: app)
            }
        }
    }

    private var wantsThumbnail: Bool { thumbnails && Thumbnails.canThumbnail(item) }
}

/// Finder-style path bar with the item count.
private struct PathBar: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 3) {
            crumb(model.bucket.name, systemImage: "externaldrive", prefix: "")
            ForEach(model.crumbs, id: \.prefix) { item in
                Image(systemName: "chevron.compact.right")
                    .foregroundStyle(.tertiary)
                crumb(item.name, systemImage: "folder.fill", prefix: item.prefix)
            }
            Spacer(minLength: 12)
            if model.isLoading && !model.items.isEmpty {
                ProgressView().controlSize(.mini)
            }
            Text(countText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func crumb(_ name: String, systemImage: String, prefix: String) -> some View {
        Button {
            model.open(prefix: prefix)
        } label: {
            Label(name, systemImage: systemImage)
                .labelStyle(PathLabelStyle())
        }
    }

    private var countText: String {
        let count = model.visibleItems.count
        let more = model.hasMore ? "+" : ""
        let selected = model.selection.count
        if selected > 0 { return "\(selected) of \(count)\(more) selected" }
        return count == 1 ? "1 item" : "\(count)\(more) items"
    }
}

private struct PathLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(Color(nsColor: .systemBlue).opacity(0.85))
            configuration.title
        }
    }
}

enum FinderDate {
    /// "Today at 9:59 AM", "Yesterday at 2:39 PM", "10 Nov 2026 at 11:18 PM".
    static func string(_ date: Date) -> String {
        guard date != .distantPast else { return "--" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated).year())) at \(time)"
    }
}

enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: BrowserItem) -> NSImage {
        let key = item.isFolder ? "/folder" : (item.name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = item.isFolder ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

// MARK: - Previews

/// Shown while a file downloads for Quick Look. Esc or the button cancels.
private struct PreviewProgress: View {
    let fraction: Double
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: fraction)
                .frame(width: 140)
            Text("Preparing preview…")
                .foregroundStyle(.secondary)
            Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

/// Quick Look-style card for files that have no visual preview (archives, disk images…).
private struct InfoPreview: View {
    let model: BrowserModel
    let item: BrowserItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 32) {
            Image(nsImage: Icons.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 160, height: 160)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.title.weight(.bold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(item.size.formatted(.byteCount(style: .file)))
                Text("Last modified on \(item.modified.formatted(date: .abbreviated, time: .standard))")
                Text(item.kind)
                    .foregroundStyle(.secondary)
                if item.size > Previews.maxBytes, Previews.canQuickLook(BrowserItem(id: item.id, name: item.name, isFolder: false, size: 0, modified: item.modified, kind: item.kind)) {
                    Text("Too large to preview. Download it to open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .font(.title3)
            .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(40)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Download") {
                    model.download([item])
                    dismiss()
                }
            }
        }
        .onKeyPress(.space) {
            dismiss()
            return .handled
        }
    }
}

// MARK: - Table header

/// Makes the SwiftUI table's header look like Finder's: the last column stretches to
/// the edge (no dangling divider after "Kind"), and no divider is drawn in the inset
/// padding before "Name". SwiftUI exposes neither, so this adjusts the backing NSTableView.
private struct FinderTableHeader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Self.apply(near: view, attempts: 50)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    /// The NSTableView is created after this view, so look again until it shows up.
    private static func apply(near view: NSView, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak view] in
            guard let view else { return }
            if let table = findTable(near: view) { configure(table) } else if attempts > 0 { apply(near: view, attempts: attempts - 1) }
        }
    }

    private static func findTable(near view: NSView) -> NSTableView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let table = tableView(in: current) { return table }
            ancestor = current.superview
        }
        return nil
    }

    private static func configure(_ table: NSTableView) {
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.sizeLastColumnToFit()
        // Swap the class of SwiftUI's own header (rather than replacing the view) so it
        // keeps its configuration; the subclass adds no stored properties.
        if let header = table.headerView, type(of: header) == NSTableHeaderView.self {
            object_setClass(header, InsetlessHeaderView.self)
            header.needsDisplay = true
        }
    }

    private static func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.headerView != nil { return table }
        for sub in view.subviews { if let table = tableView(in: sub) { return table } }
        return nil
    }
}

/// Header that skips drawing in the inset strip before the first column, where
/// AppKit otherwise puts a stray column divider. The bottom hairline still spans the width.
private final class InsetlessHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        guard let table = tableView, table.numberOfColumns > 0 else { return super.draw(dirtyRect) }
        let inset = table.rect(ofColumn: 0).minX
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: NSRect(x: inset, y: bounds.minY, width: bounds.width - inset, height: bounds.height))
        clip.append(NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.maxY - 1, width: inset, height: 1)))
        clip.addClip()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }
}
