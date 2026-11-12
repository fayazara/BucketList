import Foundation

nonisolated struct CFAccount: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
}

nonisolated struct CFBucket: Codable, Sendable, Hashable {
    var name: String
    var creation_date: String?
    var location: String?
    var jurisdiction: String?
}

nonisolated struct CloudflareAPIError: LocalizedError, Sendable {
    var status: Int
    var messages: [String]

    var errorDescription: String? {
        messages.isEmpty ? "Cloudflare API request failed (HTTP \(status))." : messages.joined(separator: "\n")
    }

    var isForbidden: Bool { status == 403 || status == 401 }
}

/// Cloudflare REST API calls made with the OAuth bearer token.
nonisolated struct CloudflareAPI: Sendable {
    /// Returns a valid access token, refreshing if needed.
    let accessToken: @Sendable () async throws -> String

    func user() async throws -> String? {
        struct User: Decodable { var email: String? }
        let user: User = try await request("GET", "/user")
        return user.email
    }

    func accounts() async throws -> [CFAccount] {
        try await request("GET", "/accounts", query: [URLQueryItem(name: "per_page", value: "50")])
    }

    func buckets(accountID: String) async throws -> [CFBucket] {
        struct Result: Decodable { var buckets: [CFBucket] }
        let result: Result = try await request(
            "GET", "/accounts/\(accountID)/r2/buckets", query: [URLQueryItem(name: "per_page", value: "1000")])
        return result.buckets
    }

    func createBucket(accountID: String, name: String) async throws {
        struct Body: Encodable { var name: String }
        let _: CFBucket = try await request("POST", "/accounts/\(accountID)/r2/buckets", body: Body(name: name))
    }

    /// Public base URL for a bucket: an active custom domain wins, then an enabled r2.dev domain.
    func publicBaseURL(accountID: String, bucket: String) async throws -> String? {
        struct Custom: Decodable {
            struct Domain: Decodable {
                struct Status: Decodable { var ownership: String?; var ssl: String? }
                var domain: String
                var enabled: Bool?
                var status: Status?
            }
            var domains: [Domain]?
        }
        struct Managed: Decodable { var domain: String?; var enabled: Bool? }

        let base = "/accounts/\(accountID)/r2/buckets/\(bucket)/domains"
        if let custom: Custom = try? await request("GET", base + "/custom"),
           let domain = custom.domains?.first(where: {
               $0.enabled == true && ($0.status?.ownership ?? "active") == "active" && ($0.status?.ssl ?? "active") == "active"
           }) {
            return "https://\(domain.domain)"
        }
        let managed: Managed = try await request("GET", base + "/managed")
        if managed.enabled == true, let domain = managed.domain { return "https://\(domain)" }
        return nil
    }

    /// Turns on public read access at the bucket's r2.dev domain and returns its base URL.
    func enableManagedDomain(accountID: String, bucket: String) async throws -> String {
        struct Body: Encodable { var enabled = true }
        struct Managed: Decodable { var domain: String?; var enabled: Bool? }
        let managed: Managed = try await request(
            "PUT", "/accounts/\(accountID)/r2/buckets/\(bucket)/domains/managed", body: Body())
        guard let domain = managed.domain else {
            throw CloudflareAPIError(status: 200, messages: ["Cloudflare didn't return an r2.dev domain."])
        }
        return "https://\(domain)"
    }

    /// Mints an account-owned API token limited to R2 object read/write and converts it to
    /// S3 credentials (Access Key ID = token id, Secret = SHA-256 of the token value).
    func createR2Credentials(accountID: String, label: String) async throws -> S3Credentials {
        struct PermissionGroup: Encodable { var id: String }
        struct Policy: Encodable {
            var effect = "allow"
            var resources: [String: [String: String]]
            var permission_groups: [PermissionGroup]
        }
        struct Body: Encodable { var name: String; var policies: [Policy] }
        struct Token: Decodable { var id: String; var value: String }

        let body = Body(name: label, policies: [
            Policy(
                resources: ["com.cloudflare.api.account.\(accountID)": ["com.cloudflare.edge.r2.bucket.*": "*"]],
                permission_groups: [PermissionGroup(id: Config.r2BucketItemWritePermissionGroup)])
        ])
        let token: Token = try await request("POST", "/accounts/\(accountID)/tokens", body: body)
        return S3Credentials(
            accessKeyID: token.id,
            secretAccessKey: SigV4.sha256Hex(Data(token.value.utf8)),
            tokenID: token.id)
    }

    func deleteToken(accountID: String, tokenID: String) async throws {
        struct Deleted: Decodable { var id: String? }
        let _: Deleted = try await request("DELETE", "/accounts/\(accountID)/tokens/\(tokenID)")
    }

    // MARK: - Plumbing

    private struct Envelope<T: Decodable>: Decodable {
        struct Message: Decodable { var code: Int?; var message: String }
        var success: Bool
        var errors: [Message]?
        var result: T?
    }

    private struct Empty: Encodable {}

    private func request<T: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = []
    ) async throws -> T {
        try await request(method, path, query: query, body: Optional<Empty>.none)
    }

    private func request<T: Decodable, B: Encodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: B?
    ) async throws -> T {
        var components = URLComponents(url: Config.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data)

        guard (200..<300).contains(status), envelope?.success != false else {
            let messages = envelope?.errors?.map { error in
                error.code.map { "\(error.message) (\($0))" } ?? error.message
            } ?? []
            throw CloudflareAPIError(status: status, messages: messages)
        }
        if let result = envelope?.result { return result }
        throw CloudflareAPIError(status: status, messages: ["Unexpected response from Cloudflare."])
    }
}
