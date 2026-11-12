import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Image thumbnails for objects, cached in memory and on disk (keyed by ETag so edits refresh).
///
/// The only way to get a thumbnail from S3 is to download the image, so this stays
/// conservative: images only, at most `maxSourceBytes`, four downloads at a time, and
/// a cell that scrolls away cancels its download.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    static let maxSourceBytes: Int64 = 12 * 1024 * 1024
    nonisolated private static let pixelSize = 400

    private let memory = NSCache<NSString, NSImage>()
    private let root: URL
    private var available = 4
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        memory.countLimit = 600
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func canThumbnail(_ item: BrowserItem) -> Bool {
        guard !item.isFolder, item.size > 0, item.size <= maxSourceBytes else { return false }
        let ext = (item.name as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) && type != .svg
    }

    func cached(_ bucket: BucketRef, _ item: BrowserItem) -> NSImage? {
        memory.object(forKey: Self.key(bucket, item) as NSString)
    }

    func thumbnail(_ bucket: BucketRef, _ item: BrowserItem, app: AppModel) async -> NSImage? {
        guard Self.canThumbnail(item) else { return nil }
        let key = Self.key(bucket, item)
        if let hit = memory.object(forKey: key as NSString) { return hit }

        let file = root.appendingPathComponent(key + ".png")
        if let image = await Self.loadFile(file) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }

        do {
            let temp = try await app.withS3(accountID: bucket.accountID) { s3 in
                try await s3.download(bucket: bucket.name, key: item.id)
            }
            let image = await Self.render(from: temp, to: file)
            // Keep the original for Quick Look, so pressing Space on it is instant.
            Previews.shared.adopt(temp, bucket, item)
            guard let image else { return nil }
            memory.setObject(image, forKey: key as NSString)
            return image
        } catch {
            return nil
        }
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Work off the main actor

    nonisolated private static func loadFile(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return NSImage(contentsOf: url)
        }.value
    }

    /// Downscales the downloaded image and writes the PNG thumbnail. Leaves the source in place.
    nonisolated private static func render(from source: URL, to destination: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
            if let out = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(out, cgImage, nil)
                CGImageDestinationFinalize(out)
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }

    // MARK: - Concurrency limit

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    private static func key(_ bucket: BucketRef, _ item: BrowserItem) -> String {
        let raw = "\(bucket.accountID)/\(bucket.name)/\(item.id)#\(item.etag ?? String(item.size))"
        return SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
