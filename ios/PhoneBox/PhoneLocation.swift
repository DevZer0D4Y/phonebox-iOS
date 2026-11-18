import CoreLocation
import Foundation

/// The phone's own place for the weather (bridge.location): the iOS app shows the weather where the phone is, like
/// the Weather app's "My Location", instead of the place typed into the computer's settings.
///
/// Asked for only once the panel shows a widget that uses the weather (bridge.wantLocation), and only "while using the
/// app". City-level accuracy is enough, so iOS's approximate location is requested; the coordinates are rounded to
/// about a kilometre before the panel sees them. The city name comes from Apple's reverse geocoder, in the phone's
/// language. Refreshed when the panel comes back to the front and when the phone has moved a few kilometres.
final class PhoneLocation: NSObject, CLLocationManagerDelegate {
    /// Called on the main thread when the place changes.
    var onChange: (() -> Void)?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var wanted = false
    private var active = false
    private var place: (lat: Double, lon: Double, city: String)?
    private var lastFix: CLLocation?

    private static let storeKey = "phoneLocation"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 3000
        // the last place, so the panel starts with it before the first fix
        if let d = UserDefaults.standard.dictionary(forKey: PhoneLocation.storeKey),
           let lat = d["lat"] as? Double, let lon = d["lon"] as? Double {
            place = (lat, lon, d["city"] as? String ?? "")
            wanted = true
        }
    }

    /// {"lat", "lon", "city"} or "" when the place is not known (yet).
    func json() -> String {
        guard let p = place else { return "" }
        return Json.string(["lat": p.lat, "lon": p.lon, "city": p.city]) ?? ""
    }

    /// From the panel: a widget shows the weather.
    func want() {
        wanted = true
        update()
    }

    func resume() {
        active = true
        update()
    }

    func pause() {
        active = false
        manager.stopUpdatingLocation()
    }

    private func update() {
        guard wanted, active else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break // refused: the place from the computer's settings stays
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        update()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0 else { return }
        if let last = lastFix, fix.distance(from: last) < 2000, place != nil { return }
        lastFix = fix
        let lat = (fix.coordinate.latitude * 100).rounded() / 100
        let lon = (fix.coordinate.longitude * 100).rounded() / 100
        set(lat, lon, place?.city ?? "")
        geocoder.reverseGeocodeLocation(fix, preferredLocale: Locale.current) { [weak self] marks, _ in
            guard let self, let m = marks?.first else { return }
            let city = m.locality ?? m.subAdministrativeArea ?? m.administrativeArea ?? ""
            DispatchQueue.main.async {
                guard let p = self.place, p.lat == lat, p.lon == lon, !city.isEmpty else { return }
                self.set(lat, lon, city)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // no fix now (indoors, airplane mode): the last place stays; iOS keeps trying while updates run
    }

    private func set(_ lat: Double, _ lon: Double, _ city: String) {
        if let p = place, p.lat == lat, p.lon == lon, p.city == city { return }
        place = (lat, lon, city)
        UserDefaults.standard.set(["lat": lat, "lon": lon, "city": city], forKey: PhoneLocation.storeKey)
        onChange?()
    }
}
