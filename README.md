# Bucket List

A native macOS app for browsing and managing your Cloudflare R2 buckets. It works like Finder.

- **Sign in with Cloudflare.** Bucket List uses OAuth, so there are no keys to copy. On first use it creates an R2-only API token for each account and turns it into S3 credentials.
- **Finder-style browsing.** List and icon views with image thumbnails, ⌘+/⌘− to resize, back/forward history, a path bar and search.
- **Quick Look.** Press Space to preview images, video, PDFs, text and documents.
- **Upload and download.** Drag files or folders in, or press ⌘U. Downloads go to ~/Downloads, and transfers show progress.
- **Links.** Copy a public link through your bucket's custom domain or r2.dev, or a private presigned link that expires after 1 hour, 1 day or 7 days.
- **Upload from Finder.** Right-click files in Finder, choose Services › Upload with Bucket List, and the link is copied for you.
- **Fast.** Folder listings are cached, appear instantly and refresh in the background. Bucket List talks to R2 directly over the S3 API: no server, no Worker and no AWS SDK.

Requires macOS 27.

## How it works

| Piece | What it does |
|---|---|
| `Auth/` | OAuth 2.0 Authorization Code with PKCE against `dash.cloudflare.com`. A one-shot loopback listener on `127.0.0.1:53682` receives the redirect. Tokens are kept in the Keychain. |
| `Cloudflare/` | Cloudflare REST API calls: accounts, buckets, public domains, and minting R2 tokens. |
| `S3/` | A small SigV4 signer and S3 client (list, get, put, delete, presign) built on `URLSession`. |
| `Model/` | App and browser state, the listing cache, thumbnails, Quick Look previews and transfers. |
| `Views/` | SwiftUI interface, menus and the Quick Look panel. |

**S3 credentials.** An R2 access key is a Cloudflare API token seen through R2's S3 API: the Access Key ID is the token's `id`, and the Secret Access Key is the SHA-256 hash of the token's value. After you sign in, Bucket List creates an account-owned token for each account with only **Workers R2 Storage Bucket Item Write** permission. Signing out deletes those tokens and revokes the OAuth grant.

**Costs.** Bucket List is only a client. It uses your own R2 account like any S3 tool would. Egress is free, listing a folder is a Class A operation, and downloads and thumbnails are Class B operations. Normal use stays well inside R2's free tier.

## Building

1. Open `Bucket List.xcodeproj` in Xcode 27.
2. Choose your own development team.
3. Run.

The OAuth client ID lives in `Bucket List/Support/Config.swift`. If you fork the app, create your own OAuth client in the Cloudflare dashboard (**Manage Account › OAuth clients**):

- **Grant types:** Authorization Code, Refresh Token
- **Token authentication method:** None (PKCE)
- **Redirect URL:** `http://127.0.0.1:53682/callback`
- **Scopes:** Workers R2 Storage (Read, Edit), Workers R2 Storage Bucket Item (Read, Edit), Account API Tokens (Edit), Account Settings (Read), User Details (Read)

Then put your client ID in `Config.swift`.

## License

[CC0 1.0](LICENSE)
