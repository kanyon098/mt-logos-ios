import CoreLocation
import WebKit

/* Second unlock condition for Screen Time blocking (2026-10-29). Kanyon: "I want
   to add two conditions to unlock. Including location... the radius should be
   like a half mile." Applies to both DnsFilter.disable() and AppBlocking's
   editing/clear — see renderBlockingSettings()/renderAppBlockingSettings() in
   mtλapp.html, which call this through the "blockLocation" bridge (WebView.swift)
   and will only show the "turn it off" controls once this reports atLocation.

   "When In Use" authorization only, checked on demand right when the web page
   asks (never continuous background tracking) — that keeps this to the lighter,
   one-time-prompt permission tier instead of "Always," a much bigger privacy/App-
   Review ask for an app that's already had three Guideline 3.1.1 rejections this
   month. This can move to continuous tracking later if a live "X mi to go"
   countdown is ever actually wanted.

   Location itself never reaches the server in either direction: this fetches the
   saved PLACES list (lat/lng/radius only, no address — see migrate-blocking-
   locations.sql) from /api/blocking/locations using the same cookie-pull trick
   IAPManager.fetchAccountToken() already uses, gets ONE current fix via
   CLLocationManager, and does the whole distance comparison right here,
   on-device. */
final class BlockLocation: NSObject, CLLocationManagerDelegate {
    static let shared = BlockLocation()

    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        // Hundred-meter accuracy is plenty of margin for a half-mile (800m) radius,
        // and resolves faster / uses less power than requesting Best.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    struct CheckResult {
        let atLocation: Bool
        let nearestLabel: String?
        let nearestMiles: Double?
        let error: String?
    }

    func check() async -> CheckResult {
        guard await ensureAuthorized() else {
            return CheckResult(atLocation: false, nearestLabel: nil, nearestMiles: nil,
                                error: "No location permission — turn it on in iPhone Settings \u{2192} Mt. Logos \u{2192} Location.")
        }
        async let locationTask = currentLocation()
        async let placesTask = fetchPlaces()
        let (location, places) = await (locationTask, placesTask)
        guard let location else {
            return CheckResult(atLocation: false, nearestLabel: nil, nearestMiles: nil, error: "Could not get your location — try again.")
        }
        guard !places.isEmpty else {
            return CheckResult(atLocation: false, nearestLabel: nil, nearestMiles: nil, error: nil)
        }
        var nearestLabel: String?
        var nearestMiles: Double?
        var atLocation = false
        for place in places {
            let meters = location.distance(from: CLLocation(latitude: place.lat, longitude: place.lng))
            let miles = meters / 1609.34
            if nearestMiles == nil || miles < nearestMiles! { nearestLabel = place.label; nearestMiles = miles }
            if meters <= place.radiusMiles * 1609.34 { atLocation = true }
        }
        return CheckResult(atLocation: atLocation, nearestLabel: nearestLabel, nearestMiles: nearestMiles, error: nil)
    }

    private func ensureAuthorized() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                authContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        @unknown default:
            return false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let continuation = authContinuation else { return }
        authContinuation = nil
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: continuation.resume(returning: true)
        default: continuation.resume(returning: false)
        }
    }

    private func currentLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(returning: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(returning: nil)
    }

    private struct Place: Decodable { let id: Int; let label: String; let lat: Double; let lng: Double; let radiusMiles: Double }
    private struct PlacesResponse: Decodable { let locations: [Place] }

    private func fetchPlaces() async -> [Place] {
        guard let url = URL(string: "https://mtlogos.com/api/blocking/locations") else { return [] }
        let cookies = await allWebViewCookies()
        guard let sid = cookies.first(where: { $0.name == "sid" && $0.domain.contains("mtlogos.com") }) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("\(sid.name)=\(sid.value)", forHTTPHeaderField: "Cookie")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return try JSONDecoder().decode(PlacesResponse.self, from: data).locations
        } catch {
            return []
        }
    }

    private func allWebViewCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}
