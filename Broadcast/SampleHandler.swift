import ReplayKit
import CoreImage
import ImageIO

/// Captures the whole iPhone screen and keeps the latest frame as a JPEG in the App Group.
/// The app picks it up from there and streams it to the car as MJPEG.
///
/// Broadcast extensions have a ~50 MB memory cap, so frames are encoded synchronously,
/// one at a time, and anything arriving faster than the target rate is dropped.
final class SampleHandler: RPBroadcastSampleHandler {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var lastFrameTime: CFTimeInterval = 0
    private var heartbeat: DispatchSourceTimer?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler {
            guard let url = Shared.heartbeatURL else { return }
            try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: url, options: .atomic)
        }
        timer.resume()
        heartbeat = timer
    }

    override func broadcastFinished() {
        heartbeat?.cancel()
        heartbeat = nil
        for url in [Shared.heartbeatURL, Shared.frameURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let url = Shared.frameURL else { return }
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= 0.9 / Shared.framesPerSecond,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = now

        autoreleasepool {
            if let jpeg = encode(pixelBuffer, orientation: orientation(of: sampleBuffer)) {
                try? jpeg.write(to: url, options: .atomic)
            }
        }
    }

    /// ReplayKit always hands over portrait buffers and says separately how the screen is turned.
    private func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                          attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else { return .up }
        return orientation
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let longSide = max(image.extent.width, image.extent.height)
        if longSide > Shared.maxFrameDimension {
            let scale = Shared.maxFrameDimension / longSide
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: Shared.jpegQuality]
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }
}
