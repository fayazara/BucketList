import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 that waits for the OAuth redirect.
///
/// Runs on the main queue; requests are tiny and there is only ever one in flight.
final class LoopbackServer {
    enum Failure: LocalizedError {
        case portInUse(UInt16)
        case listener(String)

        var errorDescription: String? {
            switch self {
            case .portInUse(let port):
                "Port \(port) is already in use by another app, so sign-in can't receive Cloudflare's reply. Quit the other app and try again."
            case .listener(let message):
                "Couldn't start the sign-in listener: \(message)"
            }
        }
    }

    private let port: UInt16
    private let path: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URLComponents, Error>?
    private var ready: CheckedContinuation<Void, Error>?

    init(port: UInt16, path: String) {
        self.port = port
        self.path = path
    }

    /// Binds the port. Throws if it is taken, before the browser is opened.
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.listener(error.localizedDescription)
        }
        self.listener = listener

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ready = cont
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.handle(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
        }
    }

    /// Waits until the browser hits the callback path and returns its URL components.
    func waitForCallback() async throws -> URLComponents {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                continuation = cont
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            ready?.resume()
            ready = nil
        case .failed(let error):
            let failure: Error =
                if case .posix(let code) = error, code == .EADDRINUSE {
                    Failure.portInUse(port)
                } else {
                    Failure.listener(error.localizedDescription)
                }
            if let ready {
                ready.resume(throwing: failure)
                self.ready = nil
            } else {
                finish(.failure(failure))
            }
            stop()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                self?.respond(to: connection, request: data ?? Data())
            }
        }
    }

    private func respond(to connection: NWConnection, request: Data) {
        // Request line: "GET /callback?code=...&state=... HTTP/1.1"
        let firstLine = String(decoding: request.prefix(8 * 1024), as: UTF8.self)
            .split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : ""
        let components = URLComponents(string: "http://127.0.0.1:\(port)\(target)")

        guard parts.first == "GET", let components, components.path == path else {
            send(connection, status: "404 Not Found", body: "Not found")
            return
        }

        let failed = components.queryItems?.contains { $0.name == "error" } ?? false
        let page = Self.page(
            title: failed ? "Sign-in didn't complete" : "You're signed in",
            message: failed
                ? "Return to Bucket List to see what went wrong."
                : "You can close this tab and return to Bucket List.")
        send(connection, status: "200 OK", body: page, contentType: "text/html; charset=utf-8")
        finish(.success(components))
    }

    private func send(_ connection: NWConnection, status: String, body: String, contentType: String = "text/plain; charset=utf-8") {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<URLComponents, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
        // Give the response a moment to flush before tearing down the listener.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.stop() }
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Bucket List</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px -apple-system, system-ui, sans-serif; display: grid; place-items: center; height: 100vh; margin: 0; }
        main { text-align: center; } h1 { font-size: 20px; font-weight: 600; margin: 0 0 8px; } p { margin: 0; opacity: .7; }
        </style></head><body><main><h1>\(title)</h1><p>\(message)</p></main></body></html>
        """
    }
}
