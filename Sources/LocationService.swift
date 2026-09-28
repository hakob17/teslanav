import Foundation
import CoreLocation

/// Runs Core Location at navigation accuracy and keeps the latest fix for the web server.
/// Background location updates are also what keep the app (and its server) alive while
/// another app is in front or the phone is locked.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var lastFix: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var snapshot: CLLocation?
    private var backgroundSession: AnyObject?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        if #available(iOS 17.0, *), backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
        }
    }

    /// `/loc` body: `{ok, lat, lng, speed, course, acc, ts, age}`. Safe to call from any thread.
    func json() -> Data {
        lock.lock()
        let fix = snapshot
        lock.unlock()

        guard let fix else { return Data(#"{"ok":false}"#.utf8) }
        let body: [String: Any] = [
            "ok": true,
            "lat": fix.coordinate.latitude,
            "lng": fix.coordinate.longitude,
            "speed": fix.speed >= 0 ? fix.speed : -1,
            "course": fix.course >= 0 ? fix.course : -1,
            "acc": fix.horizontalAccuracy,
            "ts": Int(fix.timestamp.timeIntervalSince1970 * 1000),
            // Seconds since the fix, measured on the phone so the car's clock doesn't matter.
            "age": max(0, Date().timeIntervalSince(fix.timestamp)),
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data(#"{"ok":false}"#.utf8)
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        lock.lock()
        snapshot = fix
        lock.unlock()
        lastFix = fix
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (e.g. kCLErrorLocationUnknown); Core Location keeps trying.
    }
}
