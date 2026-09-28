import Foundation
import CoreGraphics

/// Constants shared by the app and the broadcast extension. They run as separate
/// processes and meet only through the App Group (its UserDefaults and files).
enum Shared {
    static let appGroupID = "group.com.hakobhakobyan.teslanav"
    static let broadcastExtensionID = "com.hakobhakobyan.teslanav.broadcast"

    /// Where the car opens the navigation page (Map mode runs entirely in the car's browser).
    static let carPageURL = "hakob17.github.io/teslanav/car"
    /// Cloudflare relay that forwards the screen stream to the car. The car's browser refuses
    /// private addresses, so the phone can't serve the stream over the hotspot directly.
    static let relayURL = "wss://teslanav-relay.hakob-hakobyan173.workers.dev/ws"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    /// Touched every second while a broadcast runs, so the app can show it as live.
    static var heartbeatURL: URL? { containerURL?.appendingPathComponent("heartbeat") }
    static let heartbeatTimeout: TimeInterval = 3

    // MARK: Pairing

    /// 8 characters without look-alikes (no 0/O, 1/I/L), shown as XXXX-XXXX.
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private static let pairKey = "pairCode"
    private static let carsKey = "carsWatching"

    /// The code the car enters to see this phone's screen; created on first use.
    static var pairCode: String {
        if let code = defaults.string(forKey: pairKey), code.count == 8 { return code }
        return newPairCode()
    }

    @discardableResult
    static func newPairCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let code = String((0..<8).map { _ in alphabet.randomElement(using: &rng)! })
        defaults.set(code, forKey: pairKey)
        return code
    }

    static func formatted(_ code: String) -> String {
        "\(code.prefix(4))-\(code.suffix(4))"
    }

    /// How many car pages are watching the stream right now (written by the extension).
    static var carsWatching: Int {
        get { defaults.integer(forKey: carsKey) }
        set { defaults.set(newValue, forKey: carsKey) }
    }

    // MARK: Stream

    static let framesPerSecond: Double = 15
    static let maxFrameDimension: CGFloat = 1280
    static let jpegQuality: CGFloat = 0.5
    static let bitRate = 1_200_000
}
