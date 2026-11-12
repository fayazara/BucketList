import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3-compatible endpoints (R2 uses region "auto").
nonisolated struct SigV4: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    var region = "auto"
    var service = "s3"

    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    static let emptyPayloadHash = sha256Hex(Data())

    /// Returns the headers to send, including `Authorization`, `x-amz-date` and
    /// `x-amz-content-sha256`. `path` must already be URI-encoded (see `encodePath`),
    /// and `query` holds raw (unencoded) names and values.
    func signedHeaders(
        method: String,
        host: String,
        path: String,
        query: [(String, String)],
        headers: [String: String],
        payloadHash: String,
        date: Date = Date()
    ) -> [String: String] {
        let amzDate = Self.amzDate(date)
        let day = String(amzDate.prefix(8))

        var all: [String: String] = [:]
        for (name, value) in headers { all[name.lowercased()] = value }
        all["host"] = host
        all["x-amz-date"] = amzDate
        all["x-amz-content-sha256"] = payloadHash

        let names = all.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(Self.trim(all[$0]!))\n" }.joined()
        let signedNames = names.joined(separator: ";")

        let canonicalRequest = [
            method,
            path,
            Self.canonicalQuery(query),
            canonicalHeaders,
            signedNames,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signature = Self.hex(hmac(signingKey(day: day), stringToSign))
        all["authorization"] =
            "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedNames), Signature=\(signature)"
        all.removeValue(forKey: "host")  // URLSession sets Host from the URL.
        return all
    }

    /// Query-string presigned URL (only the host header is signed).
    func presignedURL(
        method: String = "GET",
        host: String,
        path: String,
        query: [(String, String)] = [],
        expires: Int,
        date: Date = Date()
    ) -> URL {
        let amzDate = Self.amzDate(date)
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"

        var q = query
        q.append(("X-Amz-Algorithm", "AWS4-HMAC-SHA256"))
        q.append(("X-Amz-Credential", "\(accessKeyID)/\(scope)"))
        q.append(("X-Amz-Date", amzDate))
        q.append(("X-Amz-Expires", String(expires)))
        q.append(("X-Amz-SignedHeaders", "host"))

        let canonicalRequest = [
            method, path, Self.canonicalQuery(q), "host:\(host)\n", "host", Self.unsignedPayload,
        ].joined(separator: "\n")
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        let signature = Self.hex(hmac(signingKey(day: day), stringToSign))

        q.append(("X-Amz-Signature", signature))
        return URL(string: "https://\(host)\(path)?\(Self.canonicalQuery(q))")!
    }

    // MARK: - Canonicalization

    /// Encodes each path segment per RFC 3986, keeping `/` separators.
    static func encodePath(_ raw: String) -> String {
        raw.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }
            .joined(separator: "/")
    }

    static func canonicalQuery(_ items: [(String, String)]) -> String {
        let encoded: [(name: String, value: String)] = items.map { (encode($0.0), encode($0.1)) }
        let sorted = encoded.sorted { a, b in
            a.name == b.name ? a.value < b.value : a.name < b.name
        }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    // MARK: - Crypto

    private func signingKey(day: String) -> SymmetricKey {
        let kDate = hmac(SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8)), day)
        let kRegion = hmac(SymmetricKey(data: kDate), region)
        let kService = hmac(SymmetricKey(data: kRegion), service)
        return SymmetricKey(data: hmac(SymmetricKey(data: kService), "aws4_request"))
    }

    private func hmac(_ key: SymmetricKey, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}
