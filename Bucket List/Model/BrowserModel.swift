import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct BrowserItem: Identifiable, Hashable {
    /// Full object key; folders end in "/".
    var id: String
    var name: String
    var isFolder: Bool
    /// -1 for folders so they sort apart from empty files.
    var size: Int64
    var modified: Date
    var kind: String
    var etag: String?
}

@Observable
final class BrowserModel {
    let bucket: BucketRef
    unowned let app: AppModel

    private(set) var prefix = ""
    private(set) var items: [BrowserItem] = []
    private(set) var isLoading = false
    private(set) var hasMore = false
    var error: String?
    var selection = Set<BrowserItem.ID>()
    var query = ""
    var sortOrder = [KeyPathComparator(\BrowserItem.name, comparator: .localizedStandard)] {
        didSet { items = sorted(items) }
    }
    /// Set when a public link was requested for a bucket with no public domain.
    var pendingPublicLink: [BrowserItem]?

    /// Items waiting for the delete confirmation (⌘⌫).
    var pendingDelete: [BrowserItem] = []
    var isImporting = false
    var isNamingFolder = false
    var folderName = ""

    func requestDelete(_ targets: [BrowserItem]? = nil) {
        let targets = targets ?? selectedItems
        if !targets.isEmpty { pendingDelete = targets }
    }

    func requestNewFolder() {
        folderName = ""
        isNamingFolder = true
    }

    var canQuickLook: Bool { selectedItems.contains { !$0.isFolder } }

    /// Local file shown in Quick Look (Space).
    var quickLookURL: URL?
    /// Item shown in the info panel when Quick Look can't render it.
    var infoItem: BrowserItem?
    /// Download progress while a preview is being fetched.
    private(set) var previewProgress: Double?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []

    @ObservationIgnored private var nextToken: String?
    @ObservationIgnored private var pagesLoaded = 0
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// How old a listing may be before focusing the window or polling refreshes it.
    private static let staleAfter: TimeInterval = 30
    /// Background refresh re-fetches at most this many pages (5,000 keys).
    private static let maxRevalidatePages = 5

    init(bucket: BucketRef, app: AppModel) {
        self.bucket = bucket
        self.app = app
    }

    /// Items after the search filter.
    var visibleItems: [BrowserItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { $0.name.localizedStandardContains(q) }
    }

    var title: String { crumbs.last?.name ?? bucket.name }

    /// Path components of the current prefix, for the path bar.
    var crumbs: [(name: String, prefix: String)] {
        var result: [(String, String)] = []
        var running = ""
        for part in prefix.split(separator: "/") {
            running += part + "/"
            result.append((String(part), running))
        }
        return result
    }

    var selectedItems: [BrowserItem] { items.filter { selection.contains($0.id) } }

    // MARK: - Navigation

    func open(prefix newPrefix: String) {
        guard newPrefix != prefix else { return }
        backStack.append(prefix)
        forwardStack = []
        show(newPrefix)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(prefix)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(prefix)
        show(next)
    }

    func goUp() {
        guard !prefix.isEmpty else { return }
        var parts = prefix.split(separator: "/")
        parts.removeLast()
        open(prefix: parts.isEmpty ? "" : parts.joined(separator: "/") + "/")
    }

    func activate(_ ids: Set<BrowserItem.ID>) {
        let targets = items.filter { ids.contains($0.id) }
        if targets.count == 1, let folder = targets.first, folder.isFolder {
            open(prefix: folder.id)
        } else {
            download(targets)
        }
    }

    // MARK: - Quick Look

    var isPreviewing: Bool { quickLookURL != nil || infoItem != nil || previewTask != nil }

    /// Space: preview the first selected file, or close the preview.
    func togglePreview() {
        if isPreviewing {
            closePreview()
        } else if let item = visibleItems.first(where: { selection.contains($0.id) && !$0.isFolder }) {
            preview(item)
        }
    }

    /// Follows the selection while a preview is open, like Finder.
    func selectionChanged() {
        guard isPreviewing else { return }
        if let item = visibleItems.first(where: { selection.contains($0.id) && !$0.isFolder }) {
            preview(item)
        } else {
            closePreview()
        }
    }

    func preview(_ item: BrowserItem) {
        previewTask?.cancel()
        previewTask = nil
        previewProgress = nil
        guard !item.isFolder else { return }

        guard Previews.canQuickLook(item) else {
            quickLookURL = nil
            infoItem = item
            return
        }
        infoItem = nil
        if let url = Previews.shared.cachedURL(bucket, item) {
            quickLookURL = url
            return
        }

        previewProgress = 0
        previewTask = Task {
            defer {
                if !Task.isCancelled {
                    previewProgress = nil
                    previewTask = nil
                }
            }
            do {
                let temp = try await app.withS3(accountID: bucket.accountID) { s3 in
                    try await s3.download(bucket: bucket.name, key: item.id, delegate: ProgressDelegate { fraction in
                        Task { @MainActor in if self.previewProgress != nil { self.previewProgress = fraction } }
                    })
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: temp)
                    return
                }
                quickLookURL = Previews.shared.adopt(temp, bucket, item)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                app.errorMessage = error.localizedDescription
            }
        }
    }

    #if DEBUG
    /// Test hook: `--args -debugQuickLook <key>` previews that object once the listing loads.
    private static var debugPreviewDone = false
    private func runDebugPreview() {
        guard !Self.debugPreviewDone, let key = UserDefaults.standard.string(forKey: "debugQuickLook"),
              let item = items.first(where: { $0.id == key }) else { return }
        Self.debugPreviewDone = true
        selection = [item.id]
        preview(item)
    }
    #endif

    func closePreview() {
        previewTask?.cancel()
        previewTask = nil
        previewProgress = nil
        quickLookURL = nil
        infoItem = nil
    }

    // MARK: - Loading (cache first, then revalidate)

    /// Shows a folder: cached contents immediately if we have them, then a fresh listing.
    func show(_ newPrefix: String) {
        closePreview()
        prefix = newPrefix
        selection = []
        query = ""
        error = nil
        loadTask?.cancel()
        generation += 1

        if let cached = DiskCache.shared.listing(bucket, prefix: newPrefix) {
            apply(objects: cached.objects, prefixes: cached.prefixes, for: newPrefix)
            nextToken = cached.nextToken
            hasMore = cached.nextToken != nil
            pagesLoaded = cached.pagesLoaded
            fetchedAt = cached.fetchedAt
            revalidate()
        } else {
            items = []
            nextToken = nil
            hasMore = false
            pagesLoaded = 0
            fetchedAt = nil
            let gen = generation
            loadTask = Task { await fetchNextPage(generation: gen) }
        }
    }

    func reload() {
        revalidate(force: true)
    }

    /// Re-fetches the loaded pages in the background and swaps them in, keeping the selection.
    func revalidate(force: Bool = false) {
        if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 2 { return }
        guard !isLoading || force else { return }
        loadTask?.cancel()
        generation += 1
        let gen = generation
        let pages = min(max(pagesLoaded, 1), Self.maxRevalidatePages)
        let prefix = self.prefix
        loadTask = Task {
            isLoading = true
            defer { if gen == generation { isLoading = false } }
            do {
                var objects: [S3Object] = []
                var prefixes: [String] = []
                var token: String?
                var fetched = 0
                repeat {
                    let page = try await list(prefix: prefix, token: token)
                    objects += page.objects
                    prefixes += page.prefixes
                    token = page.nextContinuationToken
                    fetched += 1
                } while token != nil && fetched < pages
                guard gen == generation, !Task.isCancelled else { return }

                let keep = selection
                apply(objects: objects, prefixes: prefixes, for: prefix)
                selection = keep.intersection(items.map(\.id))
                nextToken = token
                hasMore = token != nil
                pagesLoaded = fetched
                fetchedAt = Date()
                error = nil
                saveCache(objects: objects, prefixes: prefixes)
                #if DEBUG
                runDebugPreview()
                #endif
            } catch is CancellationError {
            } catch {
                guard gen == generation, !Task.isCancelled else { return }
                // Keep showing cached rows; only surface the error when there's nothing to show.
                if items.isEmpty { self.error = error.localizedDescription }
            }
        }
    }

    /// Refreshes if the listing is older than `staleAfter` (window focus, polling).
    func refreshIfStale() {
        guard let fetchedAt else { return }
        if Date().timeIntervalSince(fetchedAt) > Self.staleAfter { revalidate() }
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        let gen = generation
        loadTask = Task { await fetchNextPage(generation: gen) }
    }

    private func fetchNextPage(generation gen: Int) async {
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        let prefix = self.prefix
        do {
            let page = try await list(prefix: prefix, token: nextToken)
            guard gen == generation, !Task.isCancelled else { return }
            let existing = items
            apply(objects: page.objects, prefixes: page.prefixes, for: prefix, appendingTo: existing)
            nextToken = page.nextContinuationToken
            hasMore = nextToken != nil
            pagesLoaded += 1
            if pagesLoaded == 1 { fetchedAt = Date() }
            saveCurrentCache()
        } catch is CancellationError {
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func list(prefix: String, token: String?) async throws -> S3Listing {
        try await app.withS3(accountID: bucket.accountID) { s3 in
            try await s3.list(bucket: bucket.name, prefix: prefix, continuationToken: token)
        }
    }

    private func apply(objects: [S3Object], prefixes: [String], for prefix: String, appendingTo existing: [BrowserItem] = []) {
        let folders = prefixes.map { key in
            BrowserItem(id: key, name: Self.leaf(key), isFolder: true, size: -1, modified: .distantPast, kind: "Folder")
        }
        let files = objects
            .filter { $0.key != prefix }  // the folder's own marker object
            .map { object in
                BrowserItem(
                    id: object.key, name: Self.leaf(object.key), isFolder: false, size: object.size,
                    modified: object.lastModified ?? .distantPast, kind: Self.kind(for: object.key), etag: object.etag)
            }
        var seen = Set<String>()
        items = sorted((existing + folders + files).filter { seen.insert($0.id).inserted })
    }

    private func saveCache(objects: [S3Object], prefixes: [String]) {
        DiskCache.shared.store(
            CachedListing(objects: objects, prefixes: prefixes, nextToken: nextToken, pagesLoaded: pagesLoaded, fetchedAt: fetchedAt ?? Date()),
            bucket, prefix: prefix)
    }

    private func saveCurrentCache() {
        let objects = items.filter { !$0.isFolder }.map {
            S3Object(key: $0.id, size: $0.size, lastModified: $0.modified, etag: $0.etag)
        }
        saveCache(objects: objects, prefixes: items.filter(\.isFolder).map(\.id))
    }

    private func sorted(_ list: [BrowserItem]) -> [BrowserItem] {
        let folders = list.filter(\.isFolder).sorted(using: sortOrder)
        let files = list.filter { !$0.isFolder }.sorted(using: sortOrder)
        return folders + files
    }

    // MARK: - Actions

    func upload(_ urls: [URL]) {
        let destination = prefix
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let jobs = FileWalker.files(under: url).map { file, relativePath in
                (file, destination + relativePath, app.transfers.start(relativePath, .upload))
            }
            Task {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // URLSession limits connections per host, so starting them together is fine.
                await withTaskGroup(of: Void.self) { group in
                    for (file, key, transfer) in jobs {
                        group.addTask { _ = await self.app.upload(file: file, to: self.bucket, key: key, transfer: transfer) }
                    }
                }
                if self.prefix == destination { revalidate(force: true) }
            }
        }
    }

    func download(_ targets: [BrowserItem]) {
        guard !targets.isEmpty else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = prefix
        for item in targets {
            Task {
                do {
                    if item.isFolder {
                        let keys = try await app.withS3(accountID: bucket.accountID) { s3 in
                            try await s3.allKeys(bucket: bucket.name, prefix: item.id)
                        }
                        let root = FileWalker.unique(downloads.appendingPathComponent(item.name, isDirectory: true))
                        for key in keys where !key.hasSuffix("/") {
                            let relative = String(key.dropFirst(item.id.count))
                            await downloadOne(key: key, to: root.appendingPathComponent(relative), label: item.name + "/" + relative, reveal: false)
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    } else {
                        let label = String(item.id.dropFirst(base.count))
                        await downloadOne(key: item.id, to: FileWalker.unique(downloads.appendingPathComponent(item.name)), label: label, reveal: targets.count == 1)
                    }
                } catch {
                    app.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func downloadOne(key: String, to destination: URL, label: String, reveal: Bool) async {
        let transfer = app.transfers.start(label, .download)
        do {
            let temp = try await app.withS3(accountID: bucket.accountID) { s3 in
                try await s3.download(bucket: bucket.name, key: key, delegate: ProgressDelegate.updating(transfer))
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: destination)
            transfer.localURL = destination
            transfer.fraction = 1
            transfer.state = .done
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        } catch {
            transfer.state = .failed(error.localizedDescription)
        }
    }

    func delete(_ targets: [BrowserItem]) async {
        do {
            var keys: [String] = []
            for item in targets {
                if item.isFolder {
                    let nested = try await app.withS3(accountID: bucket.accountID) { s3 in
                        try await s3.allKeys(bucket: bucket.name, prefix: item.id)
                    }
                    keys += nested
                    if !nested.contains(item.id) { keys.append(item.id) }
                } else {
                    keys.append(item.id)
                }
            }
            try await app.withS3(accountID: bucket.accountID) { s3 in
                try await s3.delete(bucket: bucket.name, keys: keys)
            }
            let removed = Set(targets.map(\.id))
            items.removeAll { removed.contains($0.id) }
            selection.subtract(removed)
            saveCurrentCache()
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    func createFolder(named name: String) async {
        let clean = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else { return }
        let key = prefix + clean + "/"
        do {
            try await app.withS3(accountID: bucket.accountID) { s3 in
                try await s3.createFolder(bucket: bucket.name, key: key)
            }
            open(prefix: key)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    /// Presigned links that work without making anything public.
    func copyPrivateLinks(_ targets: [BrowserItem], expires: TimeInterval) async {
        do {
            let client = try await app.s3Client(accountID: bucket.accountID)
            let links = targets.filter { !$0.isFolder }.map {
                client.presignedURL(bucket: bucket.name, key: $0.id, expires: expires).absoluteString
            }
            Pasteboard.copy(links)
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    /// Permanent links through the bucket's custom domain or r2.dev. If the bucket isn't
    /// public yet, asks first (see `pendingPublicLink`).
    func copyPublicLinks(_ targets: [BrowserItem]) async {
        let files = targets.filter { !$0.isFolder }
        guard !files.isEmpty else { return }
        do {
            if let base = try await app.publicBaseURL(for: bucket) {
                Pasteboard.copy(files.map { AppModel.publicURL(base: base, key: $0.id) })
            } else {
                pendingPublicLink = files
            }
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    func enablePublicAccessAndCopy() async {
        guard let files = pendingPublicLink else { return }
        pendingPublicLink = nil
        do {
            let base = try await app.enablePublicAccess(for: bucket)
            Pasteboard.copy(files.map { AppModel.publicURL(base: base, key: $0.id) })
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private static func leaf(_ key: String) -> String {
        key.split(separator: "/").last.map(String.init) ?? key
    }

    private static func kind(for key: String) -> String {
        let ext = (key as NSString).pathExtension
        guard !ext.isEmpty else { return "Document" }
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
    }
}

enum Pasteboard {
    static func copy(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

enum FileWalker {
    /// Files to upload for a dropped URL, with their key relative to the destination prefix.
    static func files(under url: URL) -> [(URL, String)] {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDirectory else { return [(url, url.lastPathComponent)] }

        var result: [(URL, String)] = []
        let root = url.deletingLastPathComponent().standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let file = enumerator?.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(root.count + 1))
            result.append((file, relative))
        }
        return result
    }

    /// "name.ext" → "name 2.ext" if the file already exists.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for n in 2... {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
