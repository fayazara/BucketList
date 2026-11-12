import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Local copies of objects for Quick Look, in ~/Library/Caches/Previews.
/// Files keep their real name (Quick Look picks the viewer from it) and are purged
/// after a week unused.
@MainActor
final class Previews {
    static let shared = Previews()

    /// Bigger files get the info panel instead of a download.
    static let maxBytes: Int64 = 150 * 1024 * 1024
    nonisolated private static let maxAge: TimeInterval = 7 * 24 * 3600

    private let root: URL

    private init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let root = self.root
        Task.detached(priority: .background) { Self.purge(root) }
    }

    /// Types Quick Look renders with real content (anything else shows only an icon).
    static func canQuickLook(_ item: BrowserItem) -> Bool {
        guard !item.isFolder, item.size <= maxBytes else { return false }
        let ext = (item.name as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return false }
        let previewable: [UTType] = [.image, .pdf, .audiovisualContent, .text, .spreadsheet, .presentation, .usdz, .epub]
        let documents = ["com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document", "com.apple.iwork.pages.sffpages"]
        return previewable.contains { type.conforms(to: $0) } || documents.contains(type.identifier)
    }

    func cachedURL(_ bucket: BucketRef, _ item: BrowserItem) -> URL? {
        let url = location(bucket, item)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Touch it so the purge keeps files that are still being used.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Moves a downloaded file into the cache and returns its new location.
    @discardableResult
    func adopt(_ download: URL, _ bucket: BucketRef, _ item: BrowserItem) -> URL? {
        let url = location(bucket, item)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: url)
        do {
            try fm.moveItem(at: download, to: url)
            return url
        } catch {
            try? fm.removeItem(at: download)
            return nil
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func location(_ bucket: BucketRef, _ item: BrowserItem) -> URL {
        let raw = "\(bucket.accountID)/\(bucket.name)/\(item.id)#\(item.etag ?? String(item.size))"
        let hash = SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash, isDirectory: true).appendingPathComponent(item.name)
    }

    nonisolated private static func purge(_ root: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-maxAge)
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
            if newest.map({ $0 < cutoff }) ?? true { try? fm.removeItem(at: dir) }
        }
    }
}
