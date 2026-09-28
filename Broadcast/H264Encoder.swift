import Foundation
import VideoToolbox
import CoreMedia

/// Hardware H.264 encoder for screen frames, producing Annex B access units the car page can
/// hand straight to WebCodecs. Frames are scaled so the long side is at most
/// `Shared.maxFrameDimension`; key frames carry SPS/PPS inline.
final class H264Encoder {
    /// Encoded frame, in Annex B, and whether it is a key frame. Called on a VideoToolbox thread.
    var onFrame: ((Data, Bool) -> Void)?
    /// WebCodecs codec string (e.g. "avc1.640028") whenever it is first known or changes.
    var onCodec: ((String, Int, Int) -> Void)?

    private var session: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var width = 0, height = 0
    private var codec = ""
    private var frameIndex: Int64 = 0

    deinit { invalidate() }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
        codec = ""
    }

    func encode(_ source: CVPixelBuffer, forceKeyFrame: Bool) {
        let (w, h) = Self.targetSize(CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source))
        if session == nil || w != width || h != height {
            invalidate()
            guard makeSession(width: w, height: h) else { return }
        }
        guard let session, let scaled = scale(source, in: session) else { return }

        frameIndex += 1
        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(Shared.framesPerSecond))
        let props = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: scaled, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.emit(sample)
        }
    }

    // MARK: Session

    private static func targetSize(_ w: Int, _ h: Int) -> (Int, Int) {
        let scale = min(1, Double(Shared.maxFrameDimension) / Double(max(w, h)))
        // Even dimensions keep the encoder and every decoder happy.
        return (Int(Double(w) * scale) & ~1, Int(Double(h) * scale) & ~1)
    }

    private func makeSession(width: Int, height: Int) -> Bool {
        var session: VTCompressionSession?
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                         codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                         imageBufferAttributes: attributes, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { return false }

        let set = { (key: CFString, value: Any) in VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)   // no B-frames: lower latency
        set(kVTCompressionPropertyKey_AverageBitRate, Shared.bitRate)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, Shared.framesPerSecond)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int(Shared.framesPerSecond * 3))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 3)
        VTCompressionSessionPrepareToEncodeFrames(session)

        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        self.session = session
        self.transfer = transfer
        self.width = width
        self.height = height
        return true
    }

    /// Scales (and converts) the screen buffer into one from the encoder's own pool.
    private func scale(_ source: CVPixelBuffer, in session: VTCompressionSession) -> CVPixelBuffer? {
        guard let transfer, let pool = VTCompressionSessionGetPixelBufferPool(session) else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: out) == noErr else { return nil }
        return out
    }

    // MARK: Output

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private func emit(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var out = Data()
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            // SPS and PPS in front of every key frame, so a car can join at any key frame.
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                      let pointer else { continue }
                if i == 0 && size >= 4 { announceCodec(sps: pointer) }
                out.append(contentsOf: Self.startCode)
                out.append(pointer, count: size)
            }
        }

        // VideoToolbox writes AVCC (4-byte big-endian lengths); swap each length for a start code.
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let bytes = UnsafeRawPointer(pointer)
        var offset = 0
        while offset + 4 <= length {
            let nalLength = Int(bytes.load(fromByteOffset: offset, as: UInt32.self).bigEndian)
            offset += 4
            guard nalLength > 0, offset + nalLength <= length else { break }
            out.append(contentsOf: Self.startCode)
            out.append(bytes.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: nalLength)
            offset += nalLength
        }
        onFrame?(out, isKey)
    }

    /// "avc1.PPCCLL" from the SPS's profile, constraint flags and level bytes.
    private func announceCodec(sps: UnsafePointer<UInt8>) {
        let codec = String(format: "avc1.%02X%02X%02X", sps[1], sps[2], sps[3])
        guard codec != self.codec else { return }
        self.codec = codec
        onCodec?(codec, width, height)
    }
}
