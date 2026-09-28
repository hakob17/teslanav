import Foundation
import Network

/// Minimal HTTP/1.1 server on :8080 for the car's browser.
///
///     /          car web page (plus leaflet.js / leaflet.css next to it)
///     /loc       latest GPS fix as JSON
///     /status    {"mirror": true/false}
///     /mjpeg     multipart/x-mixed-replace JPEG stream of the iPhone screen
///
/// Every response except /mjpeg closes the connection. The listener restarts itself
/// if it fails, e.g. when the hotspot interface comes and goes.
final class WebServer {
    static let port: UInt16 = 8080
    private static let maxStreams = 3

    private let location: LocationService
    private let frames: FrameStore
    private let files: [String: (data: Data, type: String)]
    private let queue = DispatchQueue(label: "teslanav.web", qos: .userInitiated)
    private let lock = NSLock()

    private var listener: NWListener?
    private var streams: [ObjectIdentifier: MJPEGStream] = [:]
    private var _isReady = false
    private var _lastRequest: Date?

    var isReady: Bool { locked { _isReady } }
    /// When the car last asked for anything.
    var lastRequest: Date? { locked { _lastRequest } }
    var streamCount: Int { queue.sync { streams.count } }

    init(location: LocationService, frames: FrameStore) {
        self.location = location
        self.frames = frames
        self.files = Self.loadWebFiles()
    }

    // MARK: Listener

    func start() {
        queue.async { self.startListener() }
    }

    /// Called when the app comes to the foreground, in case the listener died meanwhile.
    func ensureRunning() {
        queue.async { if self.listener == nil { self.startListener() } }
    }

    private func startListener() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            restart(after: 2)
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.locked { self._isReady = true }
            case .failed, .cancelled:
                self.locked { self._isReady = false }
                if case .failed = state { self.restart(after: 1) }
            default:
                break
            }
        }
        // Advertising over Bonjour is what makes iOS ask for Local Network permission. A plain
        // listener never triggers the prompt, and without the permission iOS refuses every
        // connection from the car.
        listener.service = NWListener.Service(name: "TeslaNav", type: "_http._tcp")
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func restart(after seconds: Double) {
        listener?.cancel()
        listener = nil
        locked { _isReady = false }
        queue.asyncAfter(deadline: .now() + seconds) { self.startListener() }
    }

    // MARK: Requests

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
    }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.route(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.readHead(connection, buffer: buffer)
            }
        }
    }

    private func route(_ connection: NWConnection, head: String) {
        let parts = head.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return respond(connection, status: "400 Bad Request", type: "text/plain", body: Data()) }
        let method = parts[0]
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        locked { _lastRequest = Date() }

        guard method == "GET" || method == "HEAD" else {
            return respond(connection, status: "405 Method Not Allowed", type: "text/plain", body: Data())
        }
        switch path {
        case "/loc":
            respond(connection, type: "application/json", body: location.json())
        case "/status":
            let body = frames.isLive ? #"{"mirror":true}"# : #"{"mirror":false}"#
            respond(connection, type: "application/json", body: Data(body.utf8))
        case "/mjpeg":
            startStream(connection)
        default:
            let name = path == "/" ? "index.html" : String(path.dropFirst())
            if let file = files[name] {
                respond(connection, type: file.type, body: method == "HEAD" ? Data() : file.data)
            } else {
                respond(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String = "200 OK", type: String, body: Data) {
        var response = Data("""
        HTTP/1.1 \(status)\r
        Content-Type: \(type)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """.utf8)
        response.append(body)
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: MJPEG

    private func startStream(_ connection: NWConnection) {
        // The car reopens the stream on every switch to Mirror mode; drop the oldest ones.
        while streams.count >= Self.maxStreams, let oldest = streams.values.min(by: { $0.opened < $1.opened }) {
            oldest.close()
        }
        let stream = MJPEGStream(connection: connection, frames: frames, queue: queue) { [weak self] stream in
            self?.streams[ObjectIdentifier(stream)] = nil
        }
        streams[ObjectIdentifier(stream)] = stream
        stream.start()
    }

    // MARK: Files

    private static func loadWebFiles() -> [String: (data: Data, type: String)] {
        guard let dir = Bundle.main.url(forResource: "web", withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var files: [String: (data: Data, type: String)] = [:]
        for name in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            let type: String
            switch (name as NSString).pathExtension {
            case "html": type = "text/html; charset=utf-8"
            case "js": type = "text/javascript; charset=utf-8"
            case "css": type = "text/css; charset=utf-8"
            case "png": type = "image/png"
            case "svg": type = "image/svg+xml"
            default: type = "application/octet-stream"
            }
            files[name] = (data, type)
        }
        return files
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// One open `/mjpeg` response. Sends a frame only after the previous one left the socket
/// (backpressure), always skipping ahead to the newest frame, so a slow link drops frames
/// instead of building up delay.
private final class MJPEGStream {
    let opened = Date()
    private let connection: NWConnection
    private let frames: FrameStore
    private let queue: DispatchQueue
    private let onClose: (MJPEGStream) -> Void
    private var lastSeq = -1
    private var closed = false

    init(connection: NWConnection, frames: FrameStore, queue: DispatchQueue, onClose: @escaping (MJPEGStream) -> Void) {
        self.connection = connection
        self.frames = frames
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        watchForHangup()
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: multipart/x-mixed-replace; boundary=frame\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            error == nil ? self?.pump() : self?.close()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose(self)
    }

    private func watchForHangup() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, error in
            if done || error != nil { self?.close() } else { self?.watchForHangup() }
        }
    }

    private func pump() {
        guard !closed else { return }
        guard let frame = frames.latest, frame.seq != lastSeq else {
            queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.pump() }
            return
        }
        lastSeq = frame.seq
        var part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.data.count)\r\n\r\n".utf8)
        part.append(frame.data)
        part.append(Data("\r\n".utf8))
        connection.send(content: part, completion: .contentProcessed { [weak self] error in
            error == nil ? self?.pump() : self?.close()
        })
    }
}
