import ReplayKit
import CoreImage
import ImageIO

/// Captures the whole iPhone screen and streams it to the car through the relay, as H.264
/// (or JPEG for browsers that can't decode H.264). Encoding only happens while a car is
/// watching, so an idle broadcast costs no data.
///
/// Broadcast extensions have a ~50 MB memory cap: frames are handled one at a time on a
/// serial queue, and anything arriving while it is busy is dropped.
final class SampleHandler: RPBroadcastSampleHandler {
    private enum Format { case h264, jpeg }

    private let work = DispatchQueue(label: "teslanav.broadcast", qos: .userInitiated)
    private let relay = RelayClient()
    private let h264 = H264Encoder()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Touched only on `work`.
    private var format = Format.h264
    private var cars = 0
    private var needKeyFrame = true
    private var rotation = 0
    private var codec: (name: String, width: Int, height: Int)?
    private var lastBuffer: CVPixelBuffer?
    private var lastOrientation = CGImagePropertyOrientation.up
    private var busy = false
    private var lastFrameTime: CFTimeInterval = 0
    private var heartbeat: DispatchSourceTimer?
    private let start = CACurrentMediaTime()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        Shared.carsWatching = 0
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler {
            guard let url = Shared.heartbeatURL else { return }
            try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: url, options: .atomic)
        }
        timer.resume()
        heartbeat = timer

        h264.onCodec = { [weak self] name, width, height in
            self?.work.async {
                self?.codec = (name, width, height)
                self?.sendConfig()
            }
        }
        h264.onFrame = { [weak self] data, isKey in
            guard let self else { return }
            if !self.relay.send(isKey ? .keyFrame : .deltaFrame, timestamp: self.timestamp, payload: data) {
                self.work.async { self.needKeyFrame = true }   // dropped: restart from a key frame
            }
        }
        relay.onControl = { [weak self] message in self?.work.async { self?.handle(message) } }
        relay.onConnected = { [weak self] up in
            self?.work.async {
                if !up { self?.setCars(0) }
            }
        }
        relay.connect(room: Shared.pairCode)
    }

    override func broadcastFinished() {
        relay.stop()
        heartbeat?.cancel()
        heartbeat = nil
        Shared.carsWatching = 0
        if let url = Shared.heartbeatURL { try? FileManager.default.removeItem(at: url) }
        work.sync { h264.invalidate() }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = Self.orientation(of: sampleBuffer)
        let now = CACurrentMediaTime()
        work.async {
            self.lastBuffer = pixelBuffer
            self.lastOrientation = orientation
            guard self.cars > 0, !self.busy, now - self.lastFrameTime >= 0.9 / Shared.framesPerSecond else { return }
            self.lastFrameTime = now
            self.encode(pixelBuffer, orientation: orientation)
        }
    }

    // MARK: Encoding (on `work`)

    private func encode(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        busy = true
        defer { busy = false }
        let degrees = Self.degrees(orientation)
        if degrees != rotation {
            rotation = degrees
            sendConfig()
        }
        switch format {
        case .h264:
            let key = needKeyFrame
            needKeyFrame = false
            h264.encode(buffer, forceKeyFrame: key)
        case .jpeg:
            autoreleasepool {
                if let jpeg = encodeJPEG(buffer, orientation: orientation) {
                    relay.send(.jpeg, timestamp: timestamp, payload: jpeg)
                }
            }
        }
    }

    /// A car joined or asked for a fresh key frame: resend the last screen, since a static
    /// screen produces no new frames from ReplayKit.
    private func refresh() {
        needKeyFrame = true
        if let lastBuffer, cars > 0 { encode(lastBuffer, orientation: lastOrientation) }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "cars":
            setCars(message["count"] as? Int ?? 0)
        case "want":
            format = (message["format"] as? String) == "jpeg" ? .jpeg : .h264
            sendConfig()
            refresh()
        case "keyframe":
            refresh()
        default:
            break
        }
    }

    private func setCars(_ count: Int) {
        let joined = count > cars
        cars = count
        Shared.carsWatching = count
        if count == 0 { h264.invalidate(); codec = nil }
        if joined { refresh() }
    }

    private func sendConfig() {
        var config: [String: Any] = ["type": "config", "rotation": rotation]
        if format == .h264, let codec {
            config["codec"] = codec.name
            config["width"] = codec.width
            config["height"] = codec.height
        }
        relay.sendControl(config)
    }

    private func encodeJPEG(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Data? {
        // Rotation is applied on the car's side, the same as for H.264, so the image stays as captured.
        var image = CIImage(cvPixelBuffer: buffer)
        let longSide = max(image.extent.width, image.extent.height)
        if longSide > Shared.maxFrameDimension {
            let s = Shared.maxFrameDimension / longSide
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: Shared.jpegQuality]
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }

    // MARK: Helpers

    private var timestamp: UInt32 { UInt32(truncatingIfNeeded: Int((CACurrentMediaTime() - start) * 1000)) }

    /// ReplayKit always hands over portrait buffers and says separately how the screen is turned.
    private static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                          attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else { return .up }
        return orientation
    }

    /// Clockwise rotation the car must apply to show the frame upright.
    private static func degrees(_ orientation: CGImagePropertyOrientation) -> Int {
        switch orientation {
        case .right, .rightMirrored: return 90
        case .down, .downMirrored: return 180
        case .left, .leftMirrored: return 270
        default: return 0
        }
    }
}
