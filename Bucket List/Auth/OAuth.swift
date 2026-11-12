import AppKit
import CryptoKit
import Foundation

nonisolated struct OAuthTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scope: String?

    var isExpiring: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

nonisolated struct OAuthError: LocalizedError, Sendable {
    var code: String
    var detail: String?

    var errorDescription: String? {
        switch code {
        case "access_denied": "Sign-in was cancelled in the browser."
        case "invalid_scope": "The OAuth client is missing a permission this app asks for. \(detail ?? "")"
        case "state_mismatch": "The sign-in reply didn't match this request. Please try again."
        default: detail.map { "\(code): \($0)" } ?? code
        }
    }
}

/// Authorization Code + PKCE against Cloudflare, with a loopback redirect.
nonisolated enum OAuth {
    @MainActor
    static func signIn() async throws -> OAuthTokens {
        let verifier = randomURLSafe(bytes: 64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(bytes: 24)

        var components = URLComponents(url: Config.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Config.clientID),
            URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
            URLQueryItem(name: "scope", value: Config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        let server = LoopbackServer(port: Config.callbackPort, path: Config.callbackPath)
        try await server.start()
        defer { server.stop() }

        NSWorkspace.shared.open(components.url!)
        let callback = try await server.waitForCallback()
        NSApp.activate()

        // The redirect is form-encoded ("+" means space), which URLComponents doesn't decode.
        let items = Dictionary(
            (callback.percentEncodedQueryItems ?? []).map { item in
                let value = (item.value ?? "").replacingOccurrences(of: "+", with: "%20")
                return (item.name, value.removingPercentEncoding ?? value)
            },
            uniquingKeysWith: { a, _ in a })
        if let error = items["error"] {
            throw OAuthError(code: error, detail: items["error_description"])
        }
        guard items["state"] == state else { throw OAuthError(code: "state_mismatch") }
        guard let code = items["code"], !code.isEmpty else {
            throw OAuthError(code: "missing_code", detail: "Cloudflare didn't return an authorization code.")
        }

        return try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.redirectURI,
            "client_id": Config.clientID,
            "code_verifier": verifier,
        ])
    }

    static func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else {
            throw OAuthError(code: "session_expired", detail: "Your session expired. Please sign in again.")
        }
        var fresh = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Config.clientID,
        ])
        // Some servers don't rotate refresh tokens; keep the old one if none came back.
        if fresh.refreshToken == nil { fresh.refreshToken = refreshToken }
        return fresh
    }

    static func revoke(_ tokens: OAuthTokens) async {
        for token in [tokens.refreshToken, tokens.accessToken].compactMap({ $0 }) {
            var request = URLRequest(url: Config.revokeURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(["token": token, "client_id": Config.clientID])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: Config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(form)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        struct Body: Decodable {
            var access_token: String?
            var refresh_token: String?
            var expires_in: Double?
            var scope: String?
            var error: String?
            var error_description: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        guard (200..<300).contains(status), let access = body?.access_token else {
            throw OAuthError(
                code: body?.error ?? "token_error",
                detail: body?.error_description ?? "Token request failed (HTTP \(status)).")
        }
        return OAuthTokens(
            accessToken: access,
            refreshToken: body?.refresh_token,
            expiresAt: Date().addingTimeInterval(body?.expires_in ?? 3600),
            scope: body?.scope)
    }

    private static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = form.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
