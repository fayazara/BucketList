import Foundation

/// Fixed values for the Cloudflare OAuth client and R2 endpoints.
nonisolated enum Config {
    static let clientID = "fbc9f747bc08639820ef6ee95ffac8e6"

    static let authorizeURL = URL(string: "https://dash.cloudflare.com/oauth2/auth")!
    static let tokenURL = URL(string: "https://dash.cloudflare.com/oauth2/token")!
    static let revokeURL = URL(string: "https://dash.cloudflare.com/oauth2/revoke")!

    /// Loopback redirect registered on the OAuth client. Cloudflare only accepts http(s) redirects.
    static let callbackPort: UInt16 = 53682
    static let callbackPath = "/callback"
    static let redirectURI = "http://127.0.0.1:53682/callback"

    /// Scope IDs as returned by `GET /oauth/scopes`. Every one must also be enabled on the client.
    static let scopes = [
        "workers-r2.read",
        "workers-r2.write",
        "workers-r2-bucket-item.read",
        "workers-r2-bucket-item.write",
        "account-api-tokens.write",
        "account-settings.read",
        "user-details.read",
        "offline_access",
    ]

    static let apiBase = URL(string: "https://api.cloudflare.com/client/v4")!

    /// "Workers R2 Storage Bucket Item Write": read, write and list objects. Used for the
    /// account-owned token the app mints to get S3 credentials.
    static let r2BucketItemWritePermissionGroup = "2efd5506f9c8494dacb1fa10a3e7d5b6"

    static func r2Host(accountID: String) -> String {
        "\(accountID).r2.cloudflarestorage.com"
    }
}
