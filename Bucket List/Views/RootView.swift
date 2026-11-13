import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut, .signingIn:
                SignInView()
            case .signedIn:
                MainView()
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } }),
            presenting: app.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("Bucket List").font(.title.weight(.semibold))
                Text("Browse and manage your Cloudflare R2 buckets.")
                    .foregroundStyle(.secondary)
            }
            if app.phase == .signingIn {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in with your browser.")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { app.cancelSignIn() }
                }
                .padding(.top, 8)
            } else {
                Button("Sign in with Cloudflare") { app.signIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
                // Like Finder: no toolbar toggle; View › Hide Sidebar (⌃⌘S) still works.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            if let bucket = app.selection {
                // No `.id(bucket)`: keeping the view's identity keeps its toolbar
                // and search field in place while only the model is swapped.
                BrowserView(model: app.browser(for: bucket))
            } else {
                ContentUnavailableView("No Bucket Selected", systemImage: "folder",
                                       description: Text("Choose a bucket in the sidebar."))
            }
        }
        .onChange(of: app.selection) { old, _ in
            if let old { app.existingBrowser(for: old)?.closePreview() }
            QuickLookController.shared.close()
        }
    }
}
