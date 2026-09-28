import Foundation

/// Picks up screen frames the broadcast extension writes into the App Group and keeps the
/// newest one in memory with a sequence number, so each MJPEG stream sends every frame once.
final class FrameStore {
    struct Frame {
        let seq: Int
        let data: Data
    }

    private let queue = DispatchQueue(label: "teslanav.frames", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastModified: Date?
    private var seq = 0
    private var _latest: Frame?
    private var _isLive = false

    /// Newest frame while a broadcast is live, nil otherwise.
    var latest: Frame? { locked { _latest } }
    /// True while the broadcast extension is running.
    var isLive: Bool { locked { _isLive } }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        guard let frameURL = Shared.frameURL, let heartbeatURL = Shared.heartbeatURL else { return }
        let fm = FileManager.default
        let beat = (try? fm.attributesOfItem(atPath: heartbeatURL.path))?[.modificationDate] as? Date
        let live = beat.map { Date().timeIntervalSince($0) < Shared.heartbeatTimeout } ?? false

        guard live else {
            locked { _isLive = false; _latest = nil }
            lastModified = nil
            return
        }
        locked { _isLive = true }

        guard let modified = (try? fm.attributesOfItem(atPath: frameURL.path))?[.modificationDate] as? Date,
              modified != lastModified,
              let data = try? Data(contentsOf: frameURL), !data.isEmpty else { return }
        lastModified = modified
        seq += 1
        let frame = Frame(seq: seq, data: data)
        locked { _latest = frame }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
