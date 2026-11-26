import FamilyControls
import Foundation
// ApplicationToken (used throughout this file as a dictionary key) is actually defined
// in ManagedSettings, not FamilyControls — FamilyControls only re-exports it indirectly
// through FamilyActivitySelection's own properties. Missing this import is exactly what
// broke the 2026-10-11 CI build (confirmed via the real compiler error: "cannot find
// type 'ApplicationToken' in scope"), caught only once a real build actually ran.
import ManagedSettings

/* Conditional app-blocking rules (2026-10-11) — Kanyon's exact spec, in his own words:
   default is fully blocked; from there, progressively deeper OPT-IN tiers, always in
   this order:
     1. Unlock at specific times of day (otherwise blocked all day)
     2. + Total time allotted per day OR per week
     3. + Minimum time between opens (cooldown)
     4. + Max session length (auto-lock after N minutes, breaks up long scroll sessions)
   Each tier only means anything once the shallower ones are set — there's no "cooldown
   with no unlock windows" state, matching how he described it ("one layer deeper").

   This file is compiled into BOTH the main app target and MonitorExtension (see
   project.yml's `sources` list for MonitorExtension) — it's the one shared language
   between "the screen where you set the rule" (main app, SwiftUI) and "the code that
   actually enforces it in the background" (the extension, woken by Apple's system on
   its own schedule, independent of whether MtLogos.app is even running). Persisted via
   an App Group rather than plain UserDefaults specifically so both sides see the same
   data — a plain UserDefaults is sandboxed per-target and the extension could never see
   anything the main app saved otherwise. */

struct TimeWindow: Codable, Hashable {
    var startMinute: Int   // minutes since midnight, 0...1439
    var endMinute: Int     // must be > startMinute; overnight windows aren't supported in v1
}

enum BudgetPeriod: String, Codable {
    case day, week
}

/// 2026-11-26, Kanyon: a per-app location rule. `allowInside == true`: the app can only be used while this phone is
/// inside the circle. `false`: the app is blocked while inside the circle. Only a pin (lat/lng), a radius and a mode;
/// no place name is ever stored here. COMBINES WITH THE TIME RULE AS "AND": the app opens only when the time rule allows
/// AND the location rule allows. With no unlock windows set, the time rule imposes no limit (it does not mean "blocked
/// all day" any more once a location rule exists). Unknown location (permission off, no fix yet) = stays blocked.
struct LocationRule: Codable, Hashable {
    var lat: Double
    var lng: Double
    var radiusMeters: Double      // clamped 100...5000 by the editor
    var allowInside: Bool
}

struct AppBlockRule: Codable, Hashable {
    /// Optional location rule (see LocationRule). Old saved rules simply decode with nil.
    var location: LocationRule? = nil
    /// Whether this rule allows use right now as far as LOCATION goes. `inside` is the stored last-known state
    /// (nil = never determined = not allowed, fail closed).
    func locationAllows(inside: Bool?) -> Bool {
        guard let loc = location else { return true }
        guard let inside else { return false }
        return inside == loc.allowInside
    }
    /// Tier 1. Empty = fully blocked all day, every day (the default — nothing else
    /// below means anything until this has at least one window in it).
    var unlockWindows: [TimeWindow] = []
    /// Tier 2. Only meaningful once unlockWindows is non-empty.
    var budgetMinutes: Int? = nil
    var budgetPeriod: BudgetPeriod = .day
    /// Tier 3. Only meaningful once budgetMinutes is set.
    var cooldownMinutes: Int? = nil
    /// Tier 4. Only meaningful once cooldownMinutes is set.
    var sessionLimitMinutes: Int? = nil

    var isFullyBlocked: Bool { unlockWindows.isEmpty && location == nil }

    /// Clears any tier whose prerequisite tier is no longer set — keeps a rule from
    /// ending up with e.g. a session limit but no cooldown, which the UI's progressive
    /// disclosure shouldn't allow but a rule loaded from an older save might.
    mutating func normalize() {
        if unlockWindows.isEmpty { budgetMinutes = nil }
        if budgetMinutes == nil { cooldownMinutes = nil }
        if cooldownMinutes == nil { sessionLimitMinutes = nil }
    }
}

/// Total minutes covered by a set of windows — used below to catch "same number of
/// windows, but wider" as a loosening even when each individual window still fits
/// inside where an old one used to be.
private func windowsCoverMinutes(_ windows: [TimeWindow]) -> Int {
    windows.reduce(0) { $0 + max(0, $1.endMinute - $1.startMinute) }
}
/// A new window only counts as "not looser" if it sits entirely inside ONE old window —
/// allowing it to be stitched together from the gap between two old windows would let
/// genuinely new unlocked time sneak in disguised as "still inside the old windows."
private func windowContainedInUnion(_ w: TimeWindow, _ oldWindows: [TimeWindow]) -> Bool {
    oldWindows.contains { $0.startMinute <= w.startMinute && w.endMinute <= $0.endMinute }
}
/// Whether `new` is at least as strict as `old`, tier by tier — Kanyon (2026-10-30):
/// "you should be able to make any blocking more tight while the block is active, but
/// not less tight unless the partner unlocks it." Used by AppRuleEditView (commit())
/// and AppBlocking.presentRuleEditor()/presentPicker() to decide whether a change can
/// just happen, or needs the same partner-approval gate as everything else here.
/// Short-circuits the moment either side is "fully blocked" (unlockWindows empty) —
/// that's the tightest possible state regardless of what any deeper tier says, so
/// nothing past tier 1 is a meaningful comparison once that's true on either side.
/// Location part of "is this change at least as strict" (2026-11-26). Conservative on purpose: anything it cannot prove
/// is stricter counts as a loosening, so it goes through the same partner-approval gate as every other loosening.
private func locationIsTighterOrEqual(old: AppBlockRule, new: AppBlockRule) -> Bool {
    switch (old.location, new.location) {
    case (nil, nil): return true
    case (nil, .some): return true          // adding a location rule on top of time windows only restricts further
    case (.some, nil): return false         // removing a location rule is a loosening
    case (.some(let o), .some(let n)):
        if o == n { return true }
        guard abs(o.lat - n.lat) < 1e-6, abs(o.lng - n.lng) < 1e-6, o.allowInside == n.allowInside else { return false }
        return o.allowInside ? n.radiusMeters <= o.radiusMeters : n.radiusMeters >= o.radiusMeters
    }
}

func appBlockRuleIsTighterOrEqual(from old: AppBlockRule, to new: AppBlockRule) -> Bool {
    if new.isFullyBlocked { return true }    // going fully blocked is always fine
    if old.isFullyBlocked { return false }    // had nothing, now has something — a loosening
    guard locationIsTighterOrEqual(old: old, new: new) else { return false }
    if new.unlockWindows.isEmpty { return old.unlockWindows.isEmpty }   // dropping the time limit is a loosening
    if old.unlockWindows.isEmpty { return true }                        // adding a time limit to a location-only rule is stricter
    guard new.unlockWindows.allSatisfy({ windowContainedInUnion($0, old.unlockWindows) }) else { return false }
    guard windowsCoverMinutes(new.unlockWindows) <= windowsCoverMinutes(old.unlockWindows) else { return false }
    // Budget (tier 2): nil = no cap = loosest; a smaller cap is tighter.
    switch (old.budgetMinutes, new.budgetMinutes) {
    case (.some, nil): return false
    case (.some(let o), .some(let n)): if n > o { return false }
    default: break
    }
    // Cooldown (tier 3): nil = no required gap = loosest; a LARGER cooldown is tighter.
    switch (old.cooldownMinutes, new.cooldownMinutes) {
    case (.some, nil): return false
    case (.some(let o), .some(let n)): if n < o { return false }
    default: break
    }
    // Session limit (tier 4): nil = no limit = loosest; a smaller limit is tighter.
    switch (old.sessionLimitMinutes, new.sessionLimitMinutes) {
    case (.some, nil): return false
    case (.some(let o), .some(let n)): if n > o { return false }
    default: break
    }
    return true
}

/// Plain-English detail string for the partner's follow-up email (2026-11-16) — the
/// app's NAME is never knowable (see this file's own header comment), but exactly which
/// number changed and by how much always is, and was simply never surfaced before. Only
/// called once the caller already knows this edit loosened something, so this only has
/// to find and describe whichever tier(s) actually moved; never returns an empty string
/// in that case since at least one of the checks below is guaranteed to fire.
func describeRuleLoosening(from old: AppBlockRule, to new: AppBlockRule) -> String {
    var parts: [String] = []
    if old.unlockWindows.isEmpty && !new.unlockWindows.isEmpty {
        parts.append("added an unlock window (was blocked all day)")
    } else if !new.unlockWindows.allSatisfy({ windowContainedInUnion($0, old.unlockWindows) })
        || windowsCoverMinutes(new.unlockWindows) > windowsCoverMinutes(old.unlockWindows) {
        parts.append("widened the unlock window")
    }
    switch (old.budgetMinutes, new.budgetMinutes) {
    case (.some(let o), nil): parts.append("removed the \(o)min daily limit")
    case (.some(let o), .some(let n)) where n > o: parts.append("daily limit \(o) to \(n) min")
    default: break
    }
    switch (old.cooldownMinutes, new.cooldownMinutes) {
    case (.some(let o), nil): parts.append("removed the \(o)min cooldown")
    case (.some(let o), .some(let n)) where n < o: parts.append("cooldown \(o) to \(n) min")
    default: break
    }
    switch (old.sessionLimitMinutes, new.sessionLimitMinutes) {
    case (.some(let o), nil): parts.append("removed the \(o)min session limit")
    case (.some(let o), .some(let n)) where n > o: parts.append("session limit \(o) to \(n) min")
    default: break
    }
    // Action wording only: never a place name or coordinates (2026-11-26).
    if old.location != new.location { parts.append("changed a location rule") }
    return parts.isEmpty ? "loosened a limit" : parts.joined(separator: "; ")
}

/// Keyed by ApplicationToken — Apple's own opaque, Codable, Hashable identifier for a
/// selected app. Never resolvable back to a bundle id or readable name from app code
/// (by Apple's design, see AppBlocking.swift's header comment); the native rule-editor
/// screen renders a real name/icon for the person editing via SwiftUI's own Label(token),
/// which Apple provides specifically for this situation, but this code never sees that
/// string itself.
final class AppBlockingRulesStore {
    static let shared = AppBlockingRulesStore()
    private let suiteName = "group.com.mtlogos.app"
    private let key = "mtlogos.appBlockingRules"
    private var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    func loadAll() -> [ApplicationToken: AppBlockRule] {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ApplicationToken: AppBlockRule].self, from: data)
        else { return [:] }
        return decoded
    }

    func saveAll(_ rules: [ApplicationToken: AppBlockRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults?.set(data, forKey: key)
    }

    func rule(for token: ApplicationToken) -> AppBlockRule {
        loadAll()[token] ?? AppBlockRule()
    }

    func setRule(_ rule: AppBlockRule, for token: ApplicationToken) {
        var all = loadAll()
        var normalized = rule
        normalized.normalize()
        all[token] = normalized
        saveAll(all)
    }

    /// Last known inside/outside state for an app's location rule, written by the main app's LocationRuleMonitor and
    /// read by the monitor extension before it lifts a shield. nil = unknown = treated as NOT allowed.
    func locationInside(for token: ApplicationToken) -> Bool? {
        defaults?.object(forKey: "mtlogos.locInside." + tokenKey(token)) as? Bool
    }

    func setLocationInside(_ inside: Bool?, for token: ApplicationToken) {
        let k = "mtlogos.locInside." + tokenKey(token)
        if let inside { defaults?.set(inside, forKey: k) } else { defaults?.removeObject(forKey: k) }
    }

    func removeRule(for token: ApplicationToken) {
        var all = loadAll()
        all.removeValue(forKey: token)
        saveAll(all)
    }

    /// Last time each app's shield was lifted — used by the extension to enforce
    /// cooldownMinutes (tier 3), since DeviceActivityMonitor's own primitives are
    /// cumulative-usage thresholds and fixed calendar intervals, not a direct
    /// "time since last open" concept. See MonitorExtension.swift's header comment
    /// for the honest limits of this approximation.
    func lastUnshieldTime(for token: ApplicationToken) -> Date? {
        guard let data = defaults?.data(forKey: "mtlogos.lastUnshield." + tokenKey(token)) else { return nil }
        return try? JSONDecoder().decode(Date.self, from: data)
    }

    func setLastUnshieldTime(_ date: Date, for token: ApplicationToken) {
        guard let data = try? JSONEncoder().encode(date) else { return }
        defaults?.set(data, forKey: "mtlogos.lastUnshield." + tokenKey(token))
    }

    /// 2026-10-12, real bug found in a security audit: MonitorExtension's tryUnshield()
    /// only ever checked clock-tamper and cooldown before lifting a shield — it had no
    /// idea whether THIS period's budget or session threshold had already fired. A rule
    /// with two unlock windows in the same day (the data model explicitly allows this)
    /// could exhaust its budget in the first window, get correctly re-shielded by
    /// eventDidReachThreshold, and then have that shield silently undone the moment the
    /// SECOND window's own intervalDidStart fired — budget/session enforcement bypassed
    /// for the rest of the period just by having more than one window. Recording which
    /// day/week period a threshold fired in (and checking it before ever lifting a
    /// shield again) closes that: a later window in the SAME period can no longer undo
    /// an already-earned shield, while a new day/week naturally clears it just by the
    /// period key changing, with no explicit reset step needed.
    func thresholdFiredPeriodKey(for token: ApplicationToken) -> String? {
        defaults?.string(forKey: "mtlogos.thresholdFired." + tokenKey(token))
    }

    func setThresholdFiredPeriodKey(_ key: String, for token: ApplicationToken) {
        defaults?.set(key, forKey: "mtlogos.thresholdFired." + tokenKey(token))
    }

    /// A stable string identifying "which day" or "which week" a moment in time falls
    /// in, matching whichever BudgetPeriod a rule actually uses — the key changing is
    /// what lets a threshold-fired record naturally expire at the real period boundary
    /// with no separate cleanup/reset code needed.
    static func periodKey(for period: BudgetPeriod, at date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        switch period {
        case .day:
            let c = cal.dateComponents([.year, .month, .day], from: date)
            return "d\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        case .week:
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return "w\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
        }
    }

    private func tokenKey(_ token: ApplicationToken) -> String {
        guard let data = try? JSONEncoder().encode(token) else { return "unknown" }
        return data.base64EncodedString()
    }
}

/* "Prevent time change" (2026-10-11, Kanyon: "a toggle that blocks the user from
   changing the time bypassing the blocking"). Real talk, stated plainly rather than
   oversold: no sandboxed, non-MDM-supervised app can actually PREVENT someone from
   opening Settings and changing the system clock — that's a hard iOS restriction, not
   a gap in this code. What a real app CAN do is DETECT when the clock looks like it
   jumped in a way real elapsed time can't explain, and respond defensively (stay
   blocked rather than trust a suspicious clock) — that's what this does. Not
   foolproof, same honest limit as every other accountability feature in this app;
   catches the common case (someone winds the clock forward/back to dodge an unlock
   window or reset a budget) rather than a truly determined, technically sophisticated
   attempt. */
struct ClockIntegrityGuard {
    private static let suiteName = "group.com.mtlogos.app"
    private static let wallKey = "mtlogos.clockCheck.wall"
    private static let uptimeKey = "mtlogos.clockCheck.uptime"
    // 2026-11-25: the baseline now uses a clock that KEEPS COUNTING WHILE THE PHONE SLEEPS (see
    // continuousUptime()). The old ProcessInfo.systemUptime stops while the phone is asleep, so any
    // time the phone was locked for more than 5 minutes made wall-clock time look like it had jumped
    // ahead of "uptime" and set the tampered flag for no reason (the red "Looked tampered with").
    // Separate key so an old baseline from the previous clock is never compared with the new one.
    private static let cuptimeKey = "mtlogos.clockCheck.cuptime"
    private static let tamperedAtKey = "mtlogos.clockCheck.tamperedAt"
    private static func continuousUptime() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000.0
    }
    private static let tamperedKey = "mtlogos.clockCheck.tampered"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    /// Call on every app launch and every time the monitor extension fires. Compares
    /// wall-clock time elapsed since the last check against ProcessInfo's systemUptime
    /// (monotonic — unaffected by the user changing the wall clock, only reset by an
    /// actual reboot). A real device reboot also resets uptime, which would otherwise
    /// look identical to "clock wound backward" — guarded against separately below.
    /// Returns true if this check found the clock looking tampered with.
    @discardableResult
    static func checkAndRecord() -> Bool {
        let now = Date().timeIntervalSince1970
        let uptime = continuousUptime()
        defer { defaults?.set(now, forKey: wallKey); defaults?.set(uptime, forKey: cuptimeKey) }
        guard let lastWall = defaults?.double(forKey: wallKey), lastWall > 0,
              defaults?.object(forKey: cuptimeKey) != nil,
              let lastUptime = defaults?.double(forKey: cuptimeKey) else { return false }
        let wallDelta = now - lastWall
        let uptimeDelta = uptime - lastUptime
        guard uptimeDelta >= 0 else {
            /* 2026-10-12, real gap found in a security audit: a reboot used to be
               treated as "nothing to check" — the easiest real evasion of this whole
               guard is change the clock, then reboot, which lands here every time and
               walks away clean, with the new (tampered) time becoming the trusted
               baseline for every future check with no record it ever happened. A
               local reboot can forge the monotonic-uptime signal this guard otherwise
               relies on, but it can't forge what time the real server thinks it is.
               Fires a best-effort, fire-and-forget cross-check against the server's
               own clock (the Date header any HTTPS response already carries — no new
               server route needed) specifically for this case. Async, so it can't
               change this function's synchronous return value for this call; it sets
               the same tamperedKey flag retroactively if the server disagrees. */
            verifyAgainstServerTime()
            return false
        }
        let drift = abs(wallDelta - uptimeDelta)
        let tampered = drift > 300   // 5-minute tolerance for normal NTP/timezone edge cases
        if tampered {
            defaults?.set(true, forKey: tamperedKey)
            defaults?.set(now, forKey: tamperedAtKey)
        } else if defaults?.bool(forKey: tamperedKey) == true {
            // The flag still keeps shields from lifting while it is set. With the visible Dismiss link gone,
            // it clears itself once the clock has read clean for an hour (stricter than the old instant Dismiss).
            let at = defaults?.double(forKey: tamperedAtKey) ?? 0
            if at == 0 || now - at > 3600 { defaults?.set(false, forKey: tamperedKey) }
        }
        return tampered
    }

    /// Best-effort async cross-check against the server's own clock — not something a
    /// local reboot can forge, unlike ProcessInfo.systemUptime. See checkAndRecord()'s
    /// reboot branch above for why this exists. Silently does nothing if the network
    /// is unreachable; that's the same honest limit as the rest of this guard (a
    /// deliberately offline device is already outside what any client-side check
    /// alone can ever catch).
    private static func verifyAgainstServerTime() {
        guard let url = URL(string: "https://mtlogos.com/manifest.webmanifest") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let http = response as? HTTPURLResponse,
                  let dateString = http.value(forHTTPHeaderField: "Date") else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let serverDate = formatter.date(from: dateString) else { return }
            let drift = abs(Date().timeIntervalSince1970 - serverDate.timeIntervalSince1970)
            if drift > 300 {
                defaults?.set(true, forKey: tamperedKey)
                defaults?.set(Date().timeIntervalSince1970, forKey: tamperedAtKey)
            }
        }.resume()
    }

    /// Whether the most recent check (from either the main app or the extension) found
    /// tampering — surfaced to the web UI so the person (and eventually their
    /// accountability partner) can see it happened, rather than it being silent.
    static func wasTamperedRecently() -> Bool {
        defaults?.bool(forKey: tamperedKey) ?? false
    }

    /// 2026-11-23, real report: "the toggle won't stay on and keeps giving red error" —
    /// dismissing used to only clear tamperedKey, never the wall/uptime baseline that
    /// caused the flag in the first place. The very next checkAndRecord() call (from
    /// either the app or the extension, often seconds later) re-compared against that
    /// SAME stale baseline, got the SAME drift, and re-flagged tampered immediately —
    /// dismiss could never actually stick. A dismiss is the person saying "that reading
    /// was wrong, start over" — so it now also re-stamps wallKey/uptimeKey to right now,
    /// the same reset checkAndRecord() itself does on every real check, so the NEXT
    /// check measures fresh elapsed time instead of re-litigating the same old gap.
    static func clearTamperFlag() {
        defaults?.set(false, forKey: tamperedKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: wallKey)
        defaults?.set(continuousUptime(), forKey: cuptimeKey)
    }
}
