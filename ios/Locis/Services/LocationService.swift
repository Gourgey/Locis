import CoreLocation
import Observation

/// Asks for the user's location only when they ask to see it.
///
/// Only "when in use" permission is ever requested, and no location is stored or
/// sent anywhere by the app: MapKit shows the user's position on the map locally.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus
    /// Set when the user asked for their location and it became available.
    var wantsToFollowUser = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Called when the user taps the location button.
    func requestLocation() {
        wantsToFollowUser = true
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }
}
