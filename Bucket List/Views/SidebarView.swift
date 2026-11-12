import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var newBucketAccount: CFAccount?

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            ForEach(app.accounts) { account in
                Section {
                    if let error = app.bucketErrors[account.id] {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } else if let buckets = app.buckets[account.id] {
                        if buckets.isEmpty {
                            Text("No buckets").foregroundStyle(.secondary)
                        }
                        ForEach(buckets, id: \.name) { bucket in
                            Label {
                                Text(bucket.name)
                            } icon: {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                            }
                                .tag(BucketRef(accountID: account.id, name: bucket.name))
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } header: {
                    Text(account.name)
                        .contextMenu {
                            Button("New Bucket…") { newBucketAccount = account }
                            Button("Refresh") { Task { await app.loadBuckets(accountID: account.id) } }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                Text(app.email ?? "Signed in")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(app.accounts) { account in
                        Button("New Bucket in \(account.name)…") { newBucketAccount = account }
                    }
                    Divider()
                    Button("Refresh") { Task { await app.loadAccounts() } }
                    Button("Sign Out") { app.signOut() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: app.selection) { app.rememberSelection() }
        .sheet(item: $newBucketAccount) { account in
            NewBucketSheet(account: account)
        }
    }
}

struct NewBucketSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let account: CFAccount
    @State private var name = ""
    @State private var isCreating = false
    @State private var error: String?

    /// R2: 3–63 chars, lowercase letters, digits and hyphens, not starting or ending with a hyphen.
    private var isValid: Bool {
        name.wholeMatch(of: /[a-z0-9][a-z0-9-]{1,61}[a-z0-9]/) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("my-bucket"))
                    .onSubmit(create)
            } header: {
                Text("New bucket in \(account.name)")
            } footer: {
                Text(error ?? "Lowercase letters, numbers and hyphens, 3–63 characters.")
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: create)
                    .disabled(!isValid || isCreating)
            }
        }
    }

    private func create() {
        guard isValid, !isCreating else { return }
        isCreating = true
        Task {
            do {
                try await app.createBucket(accountID: account.id, name: name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isCreating = false
            }
        }
    }
}
