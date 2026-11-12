import CryptoKit
import Foundation

nonisolated struct S3Credentials: Codable, Sendable, Equatable {
    var accessKeyID: String
    var secretAccessKey: String
    /// ID of the account-owned Cloudflare API token these keys came from, if the app minted it.
    var tokenID: String?
}

nonisolated struct S3Object: Codable, Sendable, Hashable {
    var key: String
    var size: Int64
    var lastModified: Date?
    var etag: String?
}

nonisolated struct S3Listing: Sendable {
    var objects: [S3Object] = []
    var prefixes: [String] = []
    var nextContinuationToken: String?
}

nonisolated struct S3Error: LocalizedError, Sendable {
    var status: Int
    var code: String?
    var message: String?

    var errorDescription: String? {
        switch (code, message) {
        case let (code?, message?): "\(code): \(message)"
        case let (code?, nil): code
        case let (nil, message?): message
        default: "Request failed (HTTP \(status))"
        }
    }

    /// Freshly minted R2 keys can take a few seconds to become valid.
    var isAuthFailure: Bool {
        status == 401 || status == 403 || code == "InvalidAccessKeyId" || code == "Unauthorized"
    }
}

/// Minimal S3 client for R2, built on URLSession and `SigV4`.
nonisolated struct S3Client: Sendable {
    let accountID: String
    let signer: SigV4
    var session: URLSession = .shared

    init(accountID: String, credentials: S3Credentials) {
        self.accountID = accountID
        self.signer = SigV4(accessKeyID: credentials.accessKeyID, secretAccessKey: credentials.secretAccessKey)
    }

    var host: String { Config.r2Host(accountID: accountID) }

    // MARK: - Listing

    func list(bucket: String, prefix: String, delimiter: String? = "/", continuationToken: String? = nil) async throws -> S3Listing {
        var query: [(String, String)] = [("list-type", "2"), ("max-keys", "1000")]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }

        let data = try await send(method: "GET", bucket: bucket, key: nil, query: query)
        return try ListObjectsParser.parse(data)
    }

    /// Every key under `prefix` (no delimiter), following pagination.
    func allKeys(bucket: String, prefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            let page = try await list(bucket: bucket, prefix: prefix, delimiter: nil, continuationToken: token)
            keys += page.objects.map(\.key)
            token = page.nextContinuationToken
        } while token != nil
        return keys
    }

    // MARK: - Objects

    func upload(bucket: String, key: String, file: URL, contentType: String?, delegate: URLSessionTaskDelegate? = nil) async throws {
        var headers: [String: String] = [:]
        if let contentType { headers["content-type"] = contentType }
        let request = makeRequest(method: "PUT", bucket: bucket, key: key, headers: headers, payloadHash: SigV4.unsignedPayload)
        let (data, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
        try Self.check(response, data)
    }

    func createFolder(bucket: String, key: String) async throws {
        let request = makeRequest(method: "PUT", bucket: bucket, key: key, headers: [:], payloadHash: SigV4.emptyPayloadHash)
        let (data, response) = try await session.upload(for: request, from: Data())
        try Self.check(response, data)
    }

    /// Downloads to a temporary file the caller must move.
    func download(bucket: String, key: String, delegate: URLSessionTaskDelegate? = nil) async throws -> URL {
        let request = makeRequest(method: "GET", bucket: bucket, key: key, headers: [:], payloadHash: SigV4.emptyPayloadHash)
        let (url, response) = try await session.download(for: request, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = (try? Data(contentsOf: url)) ?? Data()
            try? FileManager.default.removeItem(at: url)
            try Self.check(response, body)
        }
        return url
    }

    func exists(bucket: String, key: String) async throws -> Bool {
        let request = makeRequest(method: "HEAD", bucket: bucket, key: key, headers: [:], payloadHash: SigV4.emptyPayloadHash)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return false }
        if (200..<300).contains(status) { return true }
        throw S3Error(status: status, code: nil, message: nil)
    }

    func delete(bucket: String, key: String) async throws {
        _ = try await send(method: "DELETE", bucket: bucket, key: key)
    }

    /// Deletes keys in batches of 1000 with DeleteObjects.
    func delete(bucket: String, keys: [String]) async throws {
        for start in stride(from: 0, to: keys.count, by: 1000) {
            let batch = keys[start..<min(start + 1000, keys.count)]
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete><Quiet>true</Quiet>"
            for key in batch { xml += "<Object><Key>\(Self.xmlEscape(key))</Key></Object>" }
            xml += "</Delete>"
            let body = Data(xml.utf8)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            let data = try await send(
                method: "POST", bucket: bucket, key: nil, query: [("delete", "")],
                headers: ["content-md5": md5, "content-type": "application/xml"], body: body)
            if let failure = ListObjectsParser.firstDeleteError(data) { throw failure }
        }
    }

    func presignedURL(bucket: String, key: String, expires: TimeInterval) -> URL {
        signer.presignedURL(host: host, path: path(bucket: bucket, key: key), expires: Int(expires))
    }

    // MARK: - Plumbing

    private func path(bucket: String, key: String?) -> String {
        SigV4.encodePath("/\(bucket)" + (key.map { "/\($0)" } ?? ""))
    }

    private func makeRequest(
        method: String, bucket: String, key: String?, query: [(String, String)] = [],
        headers: [String: String], payloadHash: String
    ) -> URLRequest {
        let path = path(bucket: bucket, key: key)
        let queryString = SigV4.canonicalQuery(query)
        let url = URL(string: "https://\(host)\(path)" + (queryString.isEmpty ? "" : "?\(queryString)"))!
        var request = URLRequest(url: url)
        request.httpMethod = method
        let signed = signer.signedHeaders(
            method: method, host: host, path: path, query: query, headers: headers, payloadHash: payloadHash)
        for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    @discardableResult
    private func send(
        method: String, bucket: String, key: String?, query: [(String, String)] = [],
        headers: [String: String] = [:], body: Data? = nil
    ) async throws -> Data {
        let hash = body.map { SigV4.sha256Hex($0) } ?? SigV4.emptyPayloadHash
        var request = makeRequest(method: method, bucket: bucket, key: key, query: query, headers: headers, payloadHash: hash)
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return data
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let parsed = ListObjectsParser.parseError(data)
        throw S3Error(status: http.statusCode, code: parsed.code, message: parsed.message)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - XML

/// Small XMLParser-based reader for ListObjectsV2, DeleteObjects and error bodies.
nonisolated final class ListObjectsParser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private var listing = S3Listing()
    private var current = S3Object(key: "", size: 0)
    private var truncated = false
    private var fields: [String: String] = [:]
    private var deleteErrors: [[String: String]] = []

    static func parse(_ data: Data) throws -> S3Listing {
        let delegate = ListObjectsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw S3Error(status: 200, code: "InvalidResponse", message: "Couldn't read the bucket listing.")
        }
        if !delegate.truncated { delegate.listing.nextContinuationToken = nil }
        return delegate.listing
    }

    static func parseError(_ data: Data) -> (code: String?, message: String?) {
        let delegate = ListObjectsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.fields["Error/Code"], delegate.fields["Error/Message"])
    }

    static func firstDeleteError(_ data: Data) -> S3Error? {
        let delegate = ListObjectsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let first = delegate.deleteErrors.first else { return nil }
        let key = first["Key"] ?? ""
        return S3Error(status: 200, code: first["Code"], message: "\(first["Message"] ?? "Couldn't delete") (\(key))")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(name)
        text = ""
        if path.last == "Contents" { current = S3Object(key: "", size: 0) }
        if path.suffix(2) == ["DeleteResult", "Error"] { deleteErrors.append([:]) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast(); text = "" }
        let joined = path.suffix(2).joined(separator: "/")
        switch joined {
        case "Contents/Key": current.key = text
        case "Contents/Size": current.size = Int64(text) ?? 0
        case "Contents/LastModified": current.lastModified = Self.date(text)
        case "Contents/ETag": current.etag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case "CommonPrefixes/Prefix": listing.prefixes.append(text)
        case "ListBucketResult/IsTruncated": truncated = text == "true"
        case "ListBucketResult/NextContinuationToken": listing.nextContinuationToken = text
        case "ListBucketResult/Contents": listing.objects.append(current)
        default:
            if path.count == 3, path[0] == "DeleteResult", path[1] == "Error", !deleteErrors.isEmpty {
                deleteErrors[deleteErrors.count - 1][name] = text
            } else {
                fields[joined] = text
            }
        }
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
