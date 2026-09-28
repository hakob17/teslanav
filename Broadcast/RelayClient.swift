import Foundation

/// WebSocket connection from the broadcast extension to the relay, as the "phone" side of a
/// pairing code. Reconnects on its own until stopped.
///
/// Binary messages: [kind:1][timestamp ms:4 big-endian][payload]; text messages are small
/// JSON control messages ("want", "keyframe" from the car; "cars" from the relay).
final class RelayClient: NSObject, URLSessionWebSocketDelegate {
    enum Kind: UInt8 { case keyFrame = 1, deltaFrame = 2, jpeg = 3 }

    /// Called on the client's queue with each control message.
    var onControl: (([String: Any]) -> Void)?
    /// Called when the connection is (re)established or lost.
    var onConnected: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "teslanav.relay")
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var room = ""
    private var stopped = false
    private var inFlight = 0
    private var ping: DispatchSourceTimer?

    func connect(room: String) {
        queue.async {
            self.room = room
            self.stopped = false
            self.open()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.ping?.cancel()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }
    }

    /// Sends a media message unless too many are still on their way (a slow link): then it is
    /// dropped and false returned, so the caller can restart from a key frame.
    @discardableResult
    func send(_ kind: Kind, timestamp: UInt32, payload: Data) -> Bool {
        queue.sync {
            guard let task, inFlight < 4 else { return false }
            var message = Data(capacity: payload.count + 5)
            message.append(kind.rawValue)
            withUnsafeBytes(of: timestamp.bigEndian) { message.append(contentsOf: $0) }
            message.append(payload)
            inFlight += 1
            task.send(.data(message)) { [weak self] _ in
                self?.queue.async { self?.inFlight -= 1 }
            }
            return true
        }
    }

    func sendControl(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        queue.async { self.task?.send(.string(text)) { _ in } }
    }

    // MARK: Connection

    private func open() {
        guard !stopped, var url = URLComponents(string: Shared.relayURL) else { return }
        url.queryItems = [URLQueryItem(name: "room", value: room), URLQueryItem(name: "role", value: "phone")]
        guard let target = url.url else { return }
        let task = session.webSocketTask(with: target)
        task.maximumMessageSize = 4 * 1024 * 1024
        self.task = task
        inFlight = 0
        task.resume()
        receive(on: task)
        startPing(for: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === task else { return }
                switch result {
                case .success(.string(let text)):
                    if let data = text.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onControl?(object)
                    }
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.dropped(task)
                }
            }
        }
    }

    /// Keeps idle connections (e.g. a static screen) from being closed by proxies.
    private func startPing(for task: URLSessionWebSocketTask) {
        ping?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { task.sendPing { _ in } }
        timer.resume()
        ping = timer
    }

    private func dropped(_ task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        self.task = nil
        onConnected?(false)
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 2) { self.open() }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async { if self.task === webSocketTask { self.onConnected?(true) } }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { self.dropped(webSocketTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ws = task as? URLSessionWebSocketTask else { return }
        queue.async { self.dropped(ws) }
    }
}
