import Foundation
import CoreGraphics

/// Constants shared by the app and the broadcast extension. They run as separate
/// processes and meet only through files in the App Group container.
enum Shared {
    static let appGroupID = "group.com.hakobhakobyan.teslanav"
    static let broadcastExtensionID = "com.hakobhakobyan.teslanav.broadcast"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    /// Latest screen frame, replaced atomically by the extension.
    static var frameURL: URL? { containerURL?.appendingPathComponent("frame.jpg") }
    /// Touched every second while a broadcast runs, so a static screen still reads as live.
    static var heartbeatURL: URL? { containerURL?.appendingPathComponent("heartbeat") }

    static let framesPerSecond: Double = 15
    static let maxFrameDimension: CGFloat = 1280
    static let jpegQuality: CGFloat = 0.55
    /// A broadcast counts as live while its heartbeat is younger than this.
    static let heartbeatTimeout: TimeInterval = 3
}
