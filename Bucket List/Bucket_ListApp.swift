import SwiftUI

@main
struct Bucket_ListApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Bucket List", id: "main") {
            RootView()
                .environment(delegate.app)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            ViewCommands()
            BrowserCommands()
            CommandGroup(after: .appInfo) {
                if delegate.app.phase == .signedIn {
                    Button("Sign Out") { delegate.app.signOut() }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(delegate.app)
        }
    }
}
