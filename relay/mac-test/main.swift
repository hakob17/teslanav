// Runs the broadcast extension's H264Encoder + RelayClient on the Mac with generated frames,
// streaming to the real relay as the "phone" of room MACTEST1.
import Foundation
import CoreVideo
import CoreGraphics
import AppKit

let relay = RelayClient()
let encoder = H264Encoder()
var cars = 0, wantKey = true, sent = 0, codecName = ""
let lock = NSLock()

encoder.onCodec = { name, w, h in
    codecName = name
    print("codec", name, w, h)
    relay.sendControl(["type": "config", "codec": name, "width": w, "height": h, "rotation": 0])
}
encoder.onFrame = { data, key in
    if relay.send(key ? .keyFrame : .deltaFrame, timestamp: UInt32(sent * 66), payload: data) { sent += 1 }
    else { lock.lock(); wantKey = true; lock.unlock() }
}
relay.onControl = { msg in
    print("control", msg)
    lock.lock(); defer { lock.unlock() }
    if msg["type"] as? String == "cars" { cars = msg["count"] as? Int ?? 0; wantKey = true }
    if ["keyframe", "want"].contains(msg["type"] as? String ?? "") { wantKey = true }
    if msg["type"] as? String == "want" {
        if !codecName.isEmpty { relay.sendControl(["type": "config", "codec": codecName, "width": 592, "height": 1280, "rotation": 0]) }
    }
}
relay.onConnected = { print("connected", $0) }
relay.connect(room: "MACTEST1")

func frame(_ n: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 1179, 2556, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: 1179, height: 2556, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(red: 0.1, green: 0.2 + 0.2 * sin(Double(n) / 20), blue: 0.35, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 1179, height: 2556))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ("iPhone extension\nframe \(n)" as NSString).draw(at: CGPoint(x: 80, y: 1600),
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 130), .foregroundColor: NSColor.white])
    ctx.setFillColor(.white)
    ctx.fillEllipse(in: CGRect(x: 540 + 400 * sin(Double(n) / 8), y: 700, width: 200, height: 200))
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

var n = 0
let timer = DispatchSource.makeTimerSource()
timer.schedule(deadline: .now() + 1, repeating: 1.0 / 15)
timer.setEventHandler {
    n += 1
    lock.lock(); let watching = cars > 0; let key = wantKey; wantKey = false; lock.unlock()
    if watching { encoder.encode(frame(n), forceKeyFrame: key) }
    if n % 75 == 0 { print("tick \(n) cars \(cars) sent \(sent)") }
}
timer.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + Double(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 60)) { exit(0) }
dispatchMain()
