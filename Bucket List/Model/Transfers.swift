import Foundation
import Observation

@Observable
final class Transfer: Identifiable {
    enum Direction { case upload, download }
    enum State: Equatable { case running, done, failed(String) }

    let id = UUID()
    let name: String
    let direction: Direction
    var fraction: Double = 0
    var state: State = .running
    /// Where a finished download landed.
    var localURL: URL?

    init(name: String, direction: Direction) {
        self.name = name
        self.direction = direction
    }
}

@Observable
final class TransferCenter {
    private(set) var transfers: [Transfer] = []

    var activeCount: Int { transfers.count { $0.state == .running } }

    func start(_ name: String, _ direction: Transfer.Direction) -> Transfer {
        let transfer = Transfer(name: name, direction: direction)
        transfers.insert(transfer, at: 0)
        return transfer
    }

    func clearFinished() {
        transfers.removeAll { $0.state != .running }
    }
}

/// Per-task URLSession delegate that mirrors the task's progress into a `Transfer`.
nonisolated final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let onProgress = self.onProgress
        var lastSent = -1.0
        observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            // KVO fires per chunk; only forward visible changes.
            let fraction = progress.fractionCompleted
            guard fraction - lastSent >= 0.01 || fraction >= 1 else { return }
            lastSent = fraction
            onProgress(fraction)
        }
    }

    static func updating(_ transfer: Transfer) -> ProgressDelegate {
        ProgressDelegate { fraction in
            Task { @MainActor in transfer.fraction = fraction }
        }
    }
}
