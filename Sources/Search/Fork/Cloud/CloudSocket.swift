import Foundation

// A WebSocket to the linked instance, on Cloud's pinned URLSession — so the
// same certificate fingerprint guards it as every HTTP request. Binary
// frames in and out (a text frame is handed on as its UTF-8 bytes), a ping
// every 20 s so idle proxies don't drop it. It connects once: reconnecting,
// with whatever backoff suits, is the caller's job — `onClose` says when.
//
// Made by `Cloud.shared.socket(path:query:)`, which fills in the address,
// the instance key and the token. Callbacks arrive on the main queue.

final class CloudSocket {
    var onOpen: (() -> Void)?
    var onClose: ((Error?) -> Void)?
    var onData: ((Data) -> Void)?

    private let session: URLSession
    private let request: URLRequest?
    private var task: URLSessionWebSocketTask?
    private var pinger: Timer?
    private var closed = false
    private var opened = false
    private let lock = NSLock()

    init(session: URLSession, request: URLRequest?) {
        self.session = session
        self.request = request
    }

    deinit {
        pinger?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
    }

    /// Open and confirmed by the server (the first answer to a ping or a
    /// frame arrived), and not closed since.
    var isOpen: Bool { lock.withLock { opened && !closed } }

    /// Open it. A second call on the same socket does nothing; make a new
    /// one with `Cloud.shared.socket(…)` to reconnect.
    func connect() {
        guard task == nil else { return }
        guard let request else {
            finish(Cloud.Failure(status: 0, code: "not_linked", message: "Copper isn't connected to a cloud"))
            return
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()
        receive()
        // A ping round trip is what tells a socket is really up: the task
        // reports nothing on its own when the handshake completes.
        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.finish(error) } else { self.markOpen() }
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.pinger = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.ping() }
        }
    }

    /// One binary frame.
    func send(_ data: Data) {
        guard let task, !lock.withLock({ closed }) else { return }
        task.send(.data(data)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.finish(error) }
        }
    }

    /// Close it on purpose. `onClose` is called with nil.
    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        finish(nil)
    }

    private func markOpen() {
        let first = lock.withLock { () -> Bool in
            guard !opened, !closed else { return false }
            opened = true
            return true
        }
        if first { onOpen?() }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.markOpen()
                    switch message {
                    case .data(let data): self.onData?(data)
                    case .string(let text): self.onData?(Data(text.utf8))
                    @unknown default: break
                    }
                    if !self.lock.withLock({ self.closed }) { self.receive() }
                case .failure(let error):
                    self.finish(error)
                }
            }
        }
    }

    private func ping() {
        guard let task, !lock.withLock({ closed }) else { return }
        task.sendPing { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.finish(error) }
        }
    }

    private func finish(_ error: Error?) {
        let first = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard first else { return }
        pinger?.invalidate()
        pinger = nil
        if error != nil { task?.cancel(with: .abnormalClosure, reason: nil) }
        let callback = onClose
        DispatchQueue.main.async { callback?(error) }
    }
}
