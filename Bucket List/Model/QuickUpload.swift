import AppKit
import UserNotifications

/// Finder → right-click → Services → "Upload with Bucket List".
/// Uploads to the destination chosen in Settings and copies the links.
extension AppModel {
    var quickUploadDestination: BucketRef? {
        let defaults = UserDefaults.standard
        guard let account = defaults.string(forKey: SettingsKey.quickUploadAccount),
              let bucket = defaults.string(forKey: SettingsKey.quickUploadBucket) else { return nil }
        return BucketRef(accountID: account, name: bucket)
    }

    func quickUpload(_ urls: [URL]) {
        NSApp.activate()
        guard phase == .signedIn else {
            errorMessage = "Sign in to Cloudflare first, then try the upload again."
            return
        }
        guard let destination = quickUploadDestination else {
            errorMessage = "Choose where Finder uploads go in Settings (⌘,), then try again."
            return
        }
        let defaults = UserDefaults.standard
        var prefix = (defaults.string(forKey: SettingsKey.quickUploadPrefix) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !prefix.isEmpty { prefix += "/" }
        let preferPublic = defaults.object(forKey: SettingsKey.quickUploadPreferPublic) as? Bool ?? true

        let files = urls.flatMap { FileWalker.files(under: $0) }
        guard !files.isEmpty else { return }

        Task {
            var keys: [String] = []
            await withTaskGroup(of: String?.self) { group in
                for (file, relative) in files {
                    let transfer = transfers.start(relative, .upload)
                    group.addTask {
                        let key = await self.availableKey(prefix + relative, in: destination)
                        let ok = await self.upload(file: file, to: destination, key: key, transfer: transfer)
                        return ok ? key : nil
                    }
                }
                for await key in group {
                    if let key { keys.append(key) }
                }
            }
            guard !keys.isEmpty else {
                notify(title: "Upload failed", body: "Open Bucket List's transfers to see why.")
                return
            }
            keys.sort { $0.localizedStandardCompare($1) == .orderedAscending }

            var links: [String] = []
            var kind = "Private link (7 days)"
            if preferPublic, let base = try? await publicBaseURL(for: destination) {
                links = keys.map { AppModel.publicURL(base: base, key: $0) }
                kind = "Public link"
            } else if let client = try? await s3Client(accountID: destination.accountID) {
                links = keys.map { client.presignedURL(bucket: destination.name, key: $0, expires: 604_800).absoluteString }
            }
            Pasteboard.copy(links)

            let what = keys.count == 1 ? (keys[0] as NSString).lastPathComponent : "\(keys.count) files"
            notify(title: "Uploaded \(what)", body: "\(kind)\(links.count == 1 ? "" : "s") copied to the clipboard.")
        }
    }

    /// Never overwrite: "photo.jpg" → "photo 2.jpg" if the key is taken.
    private func availableKey(_ key: String, in bucket: BucketRef) async -> String {
        let ext = (key as NSString).pathExtension
        let stem = ext.isEmpty ? key : String(key.dropLast(ext.count + 1))
        for n in 1...50 {
            let candidate = n == 1 ? key : (ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            let taken = (try? await withS3(accountID: bucket.accountID) { s3 in
                try await s3.exists(bucket: bucket.name, key: candidate)
            }) ?? false
            if !taken { return candidate }
        }
        return key
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Receives the Services menu call. Registered in `AppDelegate`; the menu item is
/// declared under `NSServices` in Info.plist.
final class ServiceProvider: NSObject {
    weak var app: AppModel?

    @objc func uploadFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files were passed to Bucket List." as NSString
            return
        }
        app?.quickUpload(urls)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.app = app
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
