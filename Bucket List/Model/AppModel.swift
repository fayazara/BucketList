import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated struct BucketRef: Hashable, Sendable {
    var accountID: String
    var name: String
}

@Observable
final class AppModel {
    enum Phase { case loading, signedOut, signingIn, signedIn }

    var phase: Phase = .loading
    var email: String?
    var accounts: [CFAccount] = []
    var buckets: [String: [CFBucket]] = [:]
    var bucketErrors: [String: String] = [:]
    var selection: BucketRef?
    var errorMessage: String?

    let transfers = TransferCenter()

    @ObservationIgnored private var tokens: OAuthTokens?
    @ObservationIgnored private var refreshTask: Task<OAuthTokens, Error>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var clients: [String: S3Client] = [:]
    @ObservationIgnored private var minting: [String: Task<S3Client, Error>] = [:]
    /// Accounts whose keys were minted this session; new keys need a moment to propagate.
    @ObservationIgnored private(set) var freshlyMinted: Set<String> = []

    private static let tokensKey = "oauth"
    private static func credentialsKey(_ accountID: String) -> String { "s3.\(accountID)" }

    @ObservationIgnored lazy var api = CloudflareAPI(accessToken: { @MainActor [weak self] in
        guard let self else { throw CancellationError() }
        return try await self.validAccessToken()
    })

    /// Public base URL per bucket (nil = not public). Filled lazily.
    @ObservationIgnored private var publicBases: [BucketRef: String?] = [:]

    init() {
        if let saved = Keychain.load(OAuthTokens.self, key: Self.tokensKey) {
            tokens = saved
            phase = .signedIn
            // Show the last known sidebar instantly, then refresh it.
            if let cached = DiskCache.shared.sidebar() {
                email = cached.email
                accounts = cached.accounts
                buckets = cached.buckets
                restoreSelection()
            }
            Task { await loadAccounts() }
        } else {
            phase = .signedOut
        }
    }

    // MARK: - Session

    func signIn() {
        guard phase != .signingIn else { return }
        phase = .signingIn
        signInTask = Task {
            do {
                let tokens = try await OAuth.signIn()
                self.tokens = tokens
                Keychain.save(tokens, key: Self.tokensKey)
                phase = .signedIn
                await loadAccounts()
            } catch is CancellationError {
                phase = .signedOut
            } catch {
                phase = .signedOut
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
    }

    func signOut() {
        let tokens = self.tokens
        let minted = accounts.compactMap { account -> (String, String)? in
            guard let id = Keychain.load(S3Credentials.self, key: Self.credentialsKey(account.id))?.tokenID else { return nil }
            return (account.id, id)
        }
        let api = self.api
        Task {
            // Remove the R2 tokens this app created, then revoke the OAuth grant.
            for (accountID, tokenID) in minted {
                try? await api.deleteToken(accountID: accountID, tokenID: tokenID)
            }
            if let tokens { await OAuth.revoke(tokens) }
        }
        reset()
    }

    private func reset() {
        Keychain.deleteAll()
        DiskCache.shared.clear()
        Thumbnails.shared.clear()
        Previews.shared.clear()
        publicBases = [:]
        tokens = nil
        refreshTask = nil
        clients = [:]
        minting = [:]
        freshlyMinted = []
        accounts = []
        buckets = [:]
        bucketErrors = [:]
        selection = nil
        email = nil
        phase = .signedOut
    }

    private func validAccessToken() async throws -> String {
        guard let tokens else { throw OAuthError(code: "signed_out", detail: "You're signed out.") }
        guard tokens.isExpiring else { return tokens.accessToken }

        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { try await OAuth.refresh(tokens) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            self.tokens = fresh
            Keychain.save(fresh, key: Self.tokensKey)
            return fresh.accessToken
        } catch let error as OAuthError {
            reset()
            errorMessage = "Your Cloudflare session expired. Please sign in again."
            throw error
        }
    }

    // MARK: - Accounts and buckets

    func loadAccounts() async {
        do {
            accounts = try await api.accounts().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if email == nil { email = try? await api.user() }
            await withTaskGroup(of: Void.self) { group in
                for account in accounts {
                    group.addTask { await self.loadBuckets(accountID: account.id) }
                }
            }
            restoreSelection()
            DiskCache.shared.storeSidebar(CachedSidebar(email: email, accounts: accounts, buckets: buckets))
        } catch {
            if phase == .signedIn { errorMessage = error.localizedDescription }
        }
    }

    func loadBuckets(accountID: String) async {
        do {
            buckets[accountID] = try await api.buckets(accountID: accountID)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            bucketErrors[accountID] = nil
        } catch {
            bucketErrors[accountID] = error.localizedDescription
        }
    }

    func createBucket(accountID: String, name: String) async throws {
        try await api.createBucket(accountID: accountID, name: name)
        await loadBuckets(accountID: accountID)
        selection = BucketRef(accountID: accountID, name: name)
    }

    func accountName(_ id: String) -> String {
        accounts.first { $0.id == id }?.name ?? id
    }

    var allBuckets: [BucketRef] {
        accounts.flatMap { account in
            (buckets[account.id] ?? []).map { BucketRef(accountID: account.id, name: $0.name) }
        }
    }

    /// Keeps the selected bucket across launches; falls back to the first bucket.
    private func restoreSelection() {
        let defaults = UserDefaults.standard
        if selection == nil,
           let account = defaults.string(forKey: "lastAccount"), let name = defaults.string(forKey: "lastBucket"),
           buckets[account]?.contains(where: { $0.name == name }) == true {
            selection = BucketRef(accountID: account, name: name)
        }
        if selection == nil, let first = allBuckets.first {
            selection = first
        }
    }

    func rememberSelection() {
        UserDefaults.standard.set(selection?.accountID, forKey: "lastAccount")
        UserDefaults.standard.set(selection?.name, forKey: "lastBucket")
    }

    // MARK: - Public links

    func publicBaseURL(for bucket: BucketRef) async throws -> String? {
        if let known = publicBases[bucket] { return known }
        let base = try await api.publicBaseURL(accountID: bucket.accountID, bucket: bucket.name)
        publicBases[bucket] = .some(base)
        return base
    }

    func enablePublicAccess(for bucket: BucketRef) async throws -> String {
        let base = try await api.enableManagedDomain(accountID: bucket.accountID, bucket: bucket.name)
        publicBases[bucket] = .some(base)
        return base
    }

    static func publicURL(base: String, key: String) -> String {
        base + SigV4.encodePath("/" + key)
    }

    // MARK: - Uploads

    /// Uploads one file and reports progress into `transfer`. Returns false on failure.
    @discardableResult
    func upload(file: URL, to bucket: BucketRef, key: String, transfer: Transfer) async -> Bool {
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
        do {
            try await withS3(accountID: bucket.accountID) { s3 in
                try await s3.upload(
                    bucket: bucket.name, key: key, file: file, contentType: type,
                    delegate: ProgressDelegate.updating(transfer))
            }
            transfer.fraction = 1
            transfer.state = .done
            return true
        } catch {
            transfer.state = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: - S3 credentials

    /// S3 client for an account, minting R2 keys on first use.
    func s3Client(accountID: String) async throws -> S3Client {
        if let client = clients[accountID] { return client }
        if let saved = Keychain.load(S3Credentials.self, key: Self.credentialsKey(accountID)) {
            let client = S3Client(accountID: accountID, credentials: saved)
            clients[accountID] = client
            return client
        }
        if let pending = minting[accountID] { return try await pending.value }

        let api = self.api
        let label = "Bucket List (\(Host.current().localizedName ?? "Mac"))"
        let task = Task<S3Client, Error> {
            do {
                let credentials = try await api.createR2Credentials(accountID: accountID, label: label)
                return S3Client(accountID: accountID, credentials: credentials)
            } catch let error as CloudflareAPIError where error.isForbidden {
                throw CloudflareAPIError(status: error.status, messages: [
                    "Bucket List couldn't create R2 access keys for this account.",
                    "Only Super Administrators can create account API tokens. Ask an admin, or sign in with an account where you have that role.",
                ] + error.messages)
            }
        }
        minting[accountID] = task
        defer { minting[accountID] = nil }

        let client = try await task.value
        let credentials = S3Credentials(
            accessKeyID: client.signer.accessKeyID, secretAccessKey: client.signer.secretAccessKey,
            tokenID: client.signer.accessKeyID)
        Keychain.save(credentials, key: Self.credentialsKey(accountID))
        clients[accountID] = client
        freshlyMinted.insert(accountID)
        return client
    }

    /// Throws away stored keys (e.g. the token was deleted in the dashboard) and mints new ones.
    func resetCredentials(accountID: String) async throws -> S3Client {
        if let old = Keychain.load(S3Credentials.self, key: Self.credentialsKey(accountID)), let tokenID = old.tokenID {
            try? await api.deleteToken(accountID: accountID, tokenID: tokenID)
        }
        Keychain.delete(key: Self.credentialsKey(accountID))
        clients[accountID] = nil
        return try await s3Client(accountID: accountID)
    }

    /// Runs an S3 operation, retrying while freshly minted keys propagate and re-minting
    /// once if stored keys have been revoked.
    func withS3<T>(accountID: String, _ operation: (S3Client) async throws -> T) async throws -> T {
        var client = try await s3Client(accountID: accountID)
        var attempt = 0
        var reminted = false
        while true {
            do {
                let result = try await operation(client)
                freshlyMinted.remove(accountID)
                return result
            } catch let error as S3Error where error.isAuthFailure {
                attempt += 1
                if freshlyMinted.contains(accountID), attempt <= 6 {
                    try await Task.sleep(for: .seconds(2))
                } else if !reminted {
                    reminted = true
                    attempt = 0
                    client = try await resetCredentials(accountID: accountID)
                } else {
                    throw error
                }
            }
        }
    }
}
