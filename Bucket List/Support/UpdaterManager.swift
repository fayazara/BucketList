import Combine
import Foundation
import Sparkle

/// Sparkle auto-updates. Created at launch; only starts in Release builds so
/// development builds never try to replace themselves.
@MainActor
final class UpdaterManager: ObservableObject {
    static let shared = UpdaterManager()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    @Published private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    private init() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func start() {
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
