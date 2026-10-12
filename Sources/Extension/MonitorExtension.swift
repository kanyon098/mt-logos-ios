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

   HONEST LIMITS, corrected 2026-10-12 after a real audit actually traced this logic
   (the original version of this comment asserted the session threshold applied
   "within the current unlock window" — it does not, and that was simply wrong, not
   an approximation; corrected below): DeviceActivityMonitor's real primitives are
   (a) a single recurring calendar interval per schedule, and (b) a cumulative-usage
   duration threshold within that interval. Neither is a perfect native fit for "a
   specific minimum gap between distinct opens" (tier 3, cooldownMinutes) or "lock
   after N continuous minutes in one sitting" (tier 4, sessionLimitMinutes) — Apple
   gives third-party apps no raw "this specific app just opened/closed" event at all,
   which is the actual root constraint behind both of the real gaps below, not a
   detail either one can be quietly patched around:

   - cooldownMinutes is ONLY re-checked in tryUnshield(), which the system only
     calls at the START of a scheduled unlock-window interval. Within an
     already-open window, nothing re-shields the app between opens, so for most
     real configurations (any cooldown shorter than the gap between scheduled
     window starts, which for a daily window is ~24 hours) this tier currently has
     no enforcement effect during that window at all — it's a stored preference the
     UI reflects accurately, but does not actually gate anything most of the time.
   - sessionLimitMinutes' threshold event is registered on the SAME day/week-long
     span as the budget event (see AppBlocking.swift's applyRule()), so it measures
     cumulative usage across the whole period, not time in one continuous sitting —
     several short, separate opens that add up can trip it exactly like one long
     session would, which does not match "breaks up long scrolling sessions," the
     feature's own stated intent.

   A later unlock window in the SAME day/week silently undoing an already-earned
   budget/session shield (a related, separately real bug) IS fixed as of 2026-10-12
   — see thresholdFiredPeriodKey in AppBlockingRulesStore and its use in both
   eventDidReachThreshold and tryUnshield below. The two gaps above are still open:
   closing them for real would mean registering many short alternating
   unlock/block sub-windows instead of one long window (approximating a reactive
   cooldown via a fixed schedule), which trades this known limitation for a
   different real risk already flagged elsewhere in this codebase — exceeding
   DeviceActivityCenter's system cap on simultaneously monitored activities,
   especially once multiplied across several blocked apps each with their own
   cooldown. Deliberately not attempted here without a product decision on that
   tradeoff first. */
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
        // 2026-10-12 fix — record that THIS period's threshold already fired, so a
        // later unlock window the same day/week can't silently undo this shield (see
        // AppBlockingRulesStore.thresholdFiredPeriodKey's own comment for the real bug
        // this closes).
        let rule = AppBlockingRulesStore.shared.rule(for: token)
        AppBlockingRulesStore.shared.setThresholdFiredPeriodKey(
            AppBlockingRulesStore.periodKey(for: rule.budgetPeriod), for: token)
    }

    private func shield(_ token: ApplicationToken) {
        var apps = store.shield.applications ?? []
        apps.insert(token)
        store.shield.applications = apps
    }

    private func tryUnshield(_ token: ApplicationToken) {
        // Clock-tamper check (see ClockIntegrityGuard's own header comment) — if the
        // wall clock looks like it jumped in a way real elapsed time can't explain,
        // don't trust this window's timing enough to lift the block.
        if ClockIntegrityGuard.checkAndRecord() {
            shield(token)
            return
        }
        let rule = AppBlockingRulesStore.shared.rule(for: token)
        // 2026-10-12 fix: a later window in the same day/week used to silently undo an
        // already-earned budget/session shield, since nothing here checked whether
        // THIS period's threshold had already fired — see thresholdFiredPeriodKey's
        // own comment for the real bug this closes.
        if let firedKey = AppBlockingRulesStore.shared.thresholdFiredPeriodKey(for: token),
           firedKey == AppBlockingRulesStore.periodKey(for: rule.budgetPeriod) {
            return
        }
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
