import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.quickUploadAccount) private var account = ""
    @AppStorage(SettingsKey.quickUploadBucket) private var bucket = ""
    @AppStorage(SettingsKey.quickUploadPrefix) private var prefix = ""
    @AppStorage(SettingsKey.quickUploadPreferPublic) private var preferPublic = true
    @State private var cacheCleared = false

    private var destination: Binding<BucketRef?> {
        Binding {
            account.isEmpty || bucket.isEmpty ? nil : BucketRef(accountID: account, name: bucket)
        } set: { ref in
            account = ref?.accountID ?? ""
            bucket = ref?.name ?? ""
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Bucket", selection: destination) {
                    Text("None").tag(BucketRef?.none)
                    ForEach(app.accounts) { account in
                        Section(account.name) {
                            ForEach(app.buckets[account.id] ?? [], id: \.name) { bucket in
                                Text(bucket.name).tag(BucketRef?.some(BucketRef(accountID: account.id, name: bucket.name)))
                            }
                        }
                    }
                }
                TextField("Folder", text: $prefix, prompt: Text("uploads"))
                Toggle("Copy public link when the bucket is public", isOn: $preferPublic)
            } header: {
                Text("Upload from Finder")
            } footer: {
                Text("Right-click files in Finder and choose Services › Upload with Bucket List. Files never overwrite existing ones. Without a public domain, a private link valid for 7 days is copied.")
                    .foregroundStyle(.secondary)
            }

            Section("Cache") {
                LabeledContent("Listings, thumbnails and previews") {
                    Button(cacheCleared ? "Cleared" : "Clear Cache") {
                        DiskCache.shared.clear()
                        Thumbnails.shared.clear()
                        Previews.shared.clear()
                        cacheCleared = true
                    }
                    .disabled(cacheCleared)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
