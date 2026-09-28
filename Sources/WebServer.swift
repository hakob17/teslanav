import Foundation
import Darwin

/// Minimal HTTP/1.1 server on :8080 for the car's browser.
///
///     /          car web page (plus leaflet.js / leaflet.css next to it)
///     /loc       latest GPS fix as JSON
///     /status    {"mirror": true/false}
///     /mjpeg     multipart/x-mixed-replace JPEG stream of the iPhone screen
///
/// Built on plain BSD sockets, one listening on 0.0.0.0 (IPv4) and one on :: (IPv6), the way
/// servers known to work over Personal Hotspot do it. An NWListener opens a single dual-stack
/// socket, and on a real iPhone connections from hotspot clients to it were refused.
///
/// Every response except /mjpeg closes the connection. Each client is served on its own
/// thread with blocking I/O, which gives MJPEG backpressure for free: the next frame is only
/// taken once the previous one has been written.
final class WebServer {
    static let port: UInt16 = 8080
    private static let maxStreams = 3

    private let location: LocationService
    private let frames: FrameStore
    private let files: [String: (data: Data, type: String)]
    private let queue = DispatchQueue(label: "teslanav.web", qos: .userInitiated)
    private let clients = DispatchQueue(label: "teslanav.web.clients", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()

    private var sockets: [Int32] = []
    private var sources: [DispatchSourceRead] = []
    private var bonjour: NetService?
    private var _lastRequest: Date?
    private var streamIDs: [Int] = []          // open MJPEG streams, oldest first
    private var nextStreamID = 0

    var isReady: Bool { queue.sync { !sockets.isEmpty } }
    /// When the car last asked for anything.
    var lastRequest: Date? { locked { _lastRequest } }
    var streamCount: Int { locked { streamIDs.count } }

    init(location: LocationService, frames: FrameStore) {
        self.location = location
        self.frames = frames
        self.files = Self.loadWebFiles()
    }

    // MARK: Listening

    func start() {
        queue.async { self.startListening() }
    }

    /// Called when the app comes to the foreground, in case the sockets died meanwhile.
    func ensureRunning() {
        queue.async { if self.sockets.isEmpty { self.startListening() } }
    }

    private func startListening() {
        guard sockets.isEmpty else { return }
        for family in [AF_INET, AF_INET6] {
            guard let fd = Self.listeningSocket(family: family) else { continue }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            sockets.append(fd)
            sources.append(source)
        }
        guard !sockets.isEmpty else {
            queue.asyncAfter(deadline: .now() + 2) { self.startListening() }
            return
        }
        // Advertising over Bonjour is what makes iOS ask for Local Network permission;
        // without it iOS refuses connections from the car.
        DispatchQueue.main.async {
            guard self.bonjour == nil else { return }
            let service = NetService(domain: "local.", type: "_http._tcp.", name: "TeslaNav", port: Int32(Self.port))
            service.publish()
            self.bonjour = service
        }
    }

    private static func listeningSocket(family: Int32) -> Int32? {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let bound: Int32
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            // IPv6 only, so it doesn't fight the IPv4 socket for the same port.
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_any
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private func acceptPending(on listeningFD: Int32) {
        while true {
            let client = accept(listeningFD, nil, nil)
            if client < 0 {
                // EAGAIN: nothing more waiting. Anything else (e.g. the network went away):
                // tear down and listen again shortly.
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { restartSoon() }
                return
            }
            // Accepted sockets inherit O_NONBLOCK from the listener; clients use blocking I/O.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            clients.async { self.serve(client) }
        }
    }

    private func restartSoon() {
        sources.forEach { $0.cancel() }
        sources = []
        sockets = []
        queue.asyncAfter(deadline: .now() + 1) { self.startListening() }
    }

    // MARK: Requests

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        guard let head = readHead(fd) else { return }
        let parts = head.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return respond(fd, status: "400 Bad Request", type: "text/plain", body: Data()) }
        let method = parts[0]
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        locked { _lastRequest = Date() }

        guard method == "GET" || method == "HEAD" else {
            return respond(fd, status: "405 Method Not Allowed", type: "text/plain", body: Data())
        }
        switch path {
        case "/loc":
            respond(fd, type: "application/json", body: location.json())
        case "/status":
            let body = frames.isLive ? #"{"mirror":true}"# : #"{"mirror":false}"#
            respond(fd, type: "application/json", body: Data(body.utf8))
        case "/mjpeg":
            stream(fd)
        default:
            let name = path == "/" ? "index.html" : String(path.dropFirst())
            if let file = files[name] {
                respond(fd, type: file.type, body: method == "HEAD" ? Data() : file.data)
            } else {
                respond(fd, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
            }
        }
    }

    private func readHead(_ fd: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let end = Data("\r\n\r\n".utf8)
        while buffer.count < 65_536 {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(chunk, count: n)
            if let range = buffer.range(of: end) {
                return String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
            }
        }
        return nil
    }

    private func respond(_ fd: Int32, status: String = "200 OK", type: String, body: Data) {
        var response = Data("""
        HTTP/1.1 \(status)\r
        Content-Type: \(type)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """.utf8)
        response.append(body)
        _ = Self.writeAll(fd, response)
    }

    /// Writes everything or fails; blocking, so a slow client slows only its own thread.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                p += n
                left -= n
            }
            return true
        }
    }

    // MARK: MJPEG

    /// Sends the newest frame whenever it changes, until the car closes the stream or a newer
    /// stream pushes this one out (the car reopens it on every switch to Mirror mode).
    private func stream(_ fd: Int32) {
        let id: Int = locked {
            nextStreamID += 1
            streamIDs.append(nextStreamID)
            if streamIDs.count > Self.maxStreams { streamIDs.removeFirst() }
            return nextStreamID
        }
        defer { locked { streamIDs.removeAll { $0 == id } } }

        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        guard Self.writeAll(fd, Data(head.utf8)) else { return }

        var lastSeq = -1
        while locked({ streamIDs.contains(id) }) {
            guard let frame = frames.latest, frame.seq != lastSeq else {
                usleep(20_000)
                continue
            }
            lastSeq = frame.seq
            var part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.data.count)\r\n\r\n".utf8)
            part.append(frame.data)
            part.append(Data("\r\n".utf8))
            guard Self.writeAll(fd, part) else { return }
        }
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
