import CryptoKit
import Foundation

nonisolated struct CachedListing: Codable, Sendable {
    var objects: [S3Object]
    var prefixes: [String]
    var nextToken: String?
    var pagesLoaded: Int
    var fetchedAt: Date
}

nonisolated struct CachedSidebar: Codable, Sendable {
    var email: String?
    var accounts: [CFAccount]
    var buckets: [String: [CFBucket]]
}

/// Small JSON cache in ~/Library/Caches for listings and the sidebar, plus an in-memory layer.
/// Everything here is disposable: it only exists so the UI can show something instantly
/// while fresh data loads.
@MainActor
final class DiskCache {
    static let shared = DiskCache()

    private var listings: [String: CachedListing] = [:]
    private let root: URL
    private let queue = DispatchQueue(label: "DiskCache", qos: .utility)

    private init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Listings", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Listings

    func listing(_ bucket: BucketRef, prefix: String) -> CachedListing? {
        let key = Self.key(bucket, prefix)
        if let hit = listings[key] { return hit }
        guard let data = try? Data(contentsOf: file(key)),
              let decoded = try? JSONDecoder().decode(CachedListing.self, from: data) else { return nil }
        listings[key] = decoded
        return decoded
    }

    func store(_ listing: CachedListing, _ bucket: BucketRef, prefix: String) {
        let key = Self.key(bucket, prefix)
        listings[key] = listing
        write(listing, to: file(key))
    }

    // MARK: Sidebar

    func sidebar() -> CachedSidebar? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("sidebar.json")) else { return nil }
        return try? JSONDecoder().decode(CachedSidebar.self, from: data)
    }

    func storeSidebar(_ sidebar: CachedSidebar) {
        write(sidebar, to: root.appendingPathComponent("sidebar.json"))
    }

    func clear() {
        listings = [:]
        let root = self.root
        queue.async {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    // MARK: Plumbing

    private func write<T: Encodable & Sendable>(_ value: T, to url: URL) {
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func file(_ key: String) -> URL {
        root.appendingPathComponent(key + ".json")
    }

    private static func key(_ bucket: BucketRef, _ prefix: String) -> String {
        let raw = "\(bucket.accountID)/\(bucket.name)/\(prefix)"
        return SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
