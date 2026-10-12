import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

/* The enforcement half of conditional app-blocking rules — see AppBlockingRules.swift's
   header for the full picture. This is a SEPARATE binary from MtLogos.app itself (an
   "app extension", declared as its own target in project.yml): Apple's system launches
   it briefly whenever a DeviceActivitySchedule interval starts/ends or a
   DeviceActivityEvent threshold is crossed, runs exactly one of the methods below, then
   suspends it again — regardless of whether the main app is open, in the background, or
   not running at all. That independence from the main app's own process is the entire
   reason this extension exists; nothing here can be done from AppBlocking.swift alone.

   HONEST LIMITS (this is the least-verified part of this session's work, flagged
   explicitly rather than presented as solved): DeviceActivityMonitor's real primitives
   are (a) a single recurring calendar interval per schedule, and (b) a cumulative-usage
   duration threshold within that interval. Neither is a perfect native fit for "a
   specific minimum gap between distinct opens" (tier 3, cooldownMinutes) or "lock after
   N continuous minutes in one sitting" (tier 4, sessionLimitMinutes) — Apple doesn't
   expose a raw "session start/end" event. The approximation used here: a session-limit
   threshold re-shields the app once that much cumulative usage is seen within the
   current unlock window (close enough to "long session" for most real usage, imperfect
   for someone who opens and closes the app repeatedly in quick bursts), and cooldown is
   enforced by checking AppBlockingRulesStore's lastUnshieldTime before lifting a shield
   again rather than through DeviceActivity's own scheduling. This needs real on-device
   iteration against actual usage patterns before trusting the exact numbers it enforces. */
class MonitorExtension: DeviceActivityMonitor {
    private let store = ManagedSettingsStore()

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard let (token, kind) = Self.decode(activity) else { return }
        if kind == .window { tryUnshield(token) }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard let (token, kind) = Self.decode(activity) else { return }
        if kind == .window { shield(token) }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard let (token, _) = Self.decode(activity) else { return }
        // Budget exhausted (tier 2) or session limit hit (tier 4) — either way, the
        // right response is the same: shield now. Budget naturally re-opens at the next
        // scheduled interval; a session-limited app only re-opens once cooldown has
        // elapsed, checked in tryUnshield() the next time its window interval starts.
        shield(token)
    }

    private func shield(_ token: ApplicationToken) {
        var apps = store.shield.applications ?? []
        apps.insert(token)
        store.shield.applications = apps
    }

    private func tryUnshield(_ token: ApplicationToken) {
        let rule = AppBlockingRulesStore.shared.rule(for: token)
        if let cooldown = rule.cooldownMinutes,
           let last = AppBlockingRulesStore.shared.lastUnshieldTime(for: token),
           Date().timeIntervalSince(last) < Double(cooldown) * 60 {
            // Cooldown not elapsed yet — stay shielded through this window.
            return
        }
        var apps = store.shield.applications ?? []
        apps.remove(token)
        store.shield.applications = apps.isEmpty ? nil : apps
        AppBlockingRulesStore.shared.setLastUnshieldTime(Date(), for: token)
    }

    private enum ActivityKind: String { case window, budget, session }

    /// AppBlocking.swift packs (token, kind, index) into the DeviceActivityName's
    /// rawValue when it registers monitoring — see its activityName(for:kind:index:) —
    /// so this extension can map "which schedule just fired" back to "which app and
    /// which tier this concerns" without a second shared lookup table.
    private static func decode(_ activity: DeviceActivityName) -> (ApplicationToken, ActivityKind)? {
        let parts = activity.rawValue.split(separator: "|", maxSplits: 2)
        guard parts.count >= 2,
              let kind = ActivityKind(rawValue: String(parts[0])),
              let data = Data(base64Encoded: String(parts[1])),
              let token = try? JSONDecoder().decode(ApplicationToken.self, from: data)
        else { return nil }
        return (token, kind)
    }
}
