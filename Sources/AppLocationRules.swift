import CoreLocation
import CryptoKit
import FamilyControls
import Foundation
import ManagedSettings

/* Per-app LOCATION rules (2026-11-26, Kanyon): "if I am inside this radius I CAN use this app" or "I CANNOT use this
   app". See LocationRule / AppBlockRule.locationAllows in AppBlockingRules.swift for the model and the combine rule
   (time rule AND location rule must both allow; unknown location stays blocked).

   HOW IT IS ENFORCED: one geofence (CLCircularRegion) per app that has a location rule. iOS wakes this app in the
   background when the phone enters or leaves a circle (needs "Always" location access; no paid service, no background
   mode entry needed for region monitoring, iOS allows 20 regions per app). Each event stores inside/outside in the App
   Group (read by the monitor extension too) and re-applies that app's shield right away. Apps whose location state is
   unknown (permission off, nothing determined yet) stay shielded. Cooldown/session tiers are not re-evaluated here;
   the time windows, the period budget and the clock-tamper flag are. */
final class LocationRuleMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = LocationRuleMonitor()

    private let manager = CLLocationManager()
    private let store = ManagedSettingsStore()
    private var askedAlways = false

    private override init() {
        super.init()
        manager.delegate = self
    }

    /// True when iOS will deliver region events in the background (Always access).
    var hasAlwaysAccess: Bool { manager.authorizationStatus == .authorizedAlways }

    private func regionId(_ token: ApplicationToken) -> String {
        let data = (try? JSONEncoder().encode(token)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Call after any rule change and at launch. Safe to call often.
    func sync() {
        DispatchQueue.main.async { self.syncNow() }
    }

    private func syncNow() {
        let rulesStore = AppBlockingRulesStore.shared
        let rules = rulesStore.loadAll()
        let wanted = rules.filter { $0.value.location != nil }
        for (token, rule) in rules where rule.location == nil { rulesStore.setLocationInside(nil, for: token) }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        if !wanted.isEmpty, !askedAlways {
            let s = manager.authorizationStatus
            if s == .notDetermined || s == .authorizedWhenInUse { askedAlways = true; manager.requestAlwaysAuthorization() }
        }
        var wantedIds = Set<String>()
        for (token, rule) in wanted {
            guard let loc = rule.location else { continue }
            let id = regionId(token)
            wantedIds.insert(id)
            let center = CLLocationCoordinate2D(latitude: loc.lat, longitude: loc.lng)
            let radius = min(max(loc.radiusMeters, 100), min(manager.maximumRegionMonitoringDistance, 20000))
            if let existing = manager.monitoredRegions.first(where: { $0.identifier == id }) as? CLCircularRegion,
               existing.center.latitude == center.latitude, existing.center.longitude == center.longitude, existing.radius == radius {
                manager.requestState(for: existing)
            } else {
                let region = CLCircularRegion(center: center, radius: radius, identifier: id)
                region.notifyOnEntry = true
                region.notifyOnExit = true
                manager.startMonitoring(for: region)
                manager.requestState(for: region)
            }
        }
        for r in manager.monitoredRegions where !wantedIds.contains(r.identifier) { manager.stopMonitoring(for: r) }
        for (token, _) in wanted { reconcile(token) }
    }

    private func token(forRegion id: String) -> ApplicationToken? {
        AppBlockingRulesStore.shared.loadAll().first(where: { $0.value.location != nil && regionId($0.key) == id })?.key
    }

    private func handle(_ region: CLRegion, inside: Bool?) {
        guard let token = token(forRegion: region.identifier) else { return }
        if let inside { AppBlockingRulesStore.shared.setLocationInside(inside, for: token) }
        reconcile(token)
    }

    /// Re-applies ONE app's shield from the current time rule AND location rule.
    private func reconcile(_ token: ApplicationToken) {
        let rulesStore = AppBlockingRulesStore.shared
        let rule = rulesStore.rule(for: token)
        guard rule.location != nil else { return }
        var apps = store.shield.applications ?? []
        if rule.locationAllows(inside: rulesStore.locationInside(for: token)) && timeAllowsNow(rule, token) {
            apps.remove(token)
        } else {
            apps.insert(token)
        }
        store.shield.applications = apps.isEmpty ? nil : apps
    }

    /// The time half of the combine rule. No windows = no time limit (a location-only rule).
    private func timeAllowsNow(_ rule: AppBlockRule, _ token: ApplicationToken) -> Bool {
        if ClockIntegrityGuard.wasTamperedRecently() { return false }
        if rule.unlockWindows.isEmpty { return true }
        let rulesStore = AppBlockingRulesStore.shared
        if let fired = rulesStore.thresholdFiredPeriodKey(for: token),
           fired == AppBlockingRulesStore.periodKey(for: rule.budgetPeriod) { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return rule.unlockWindows.contains { $0.startMinute <= m && m < $0.endMinute }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        switch state {
        case .inside: handle(region, inside: true)
        case .outside: handle(region, inside: false)
        default: handle(region, inside: nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) { handle(region, inside: true) }
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { handle(region, inside: false) }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { syncNow() }
}
