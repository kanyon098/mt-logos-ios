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

struct AppBlockRule: Codable, Hashable {
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

    var isFullyBlocked: Bool { unlockWindows.isEmpty }

    /// Clears any tier whose prerequisite tier is no longer set — keeps a rule from
    /// ending up with e.g. a session limit but no cooldown, which the UI's progressive
    /// disclosure shouldn't allow but a rule loaded from an older save might.
    mutating func normalize() {
        if unlockWindows.isEmpty { budgetMinutes = nil }
        if budgetMinutes == nil { cooldownMinutes = nil }
        if cooldownMinutes == nil { sessionLimitMinutes = nil }
    }
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
        let uptime = ProcessInfo.processInfo.systemUptime
        defer { defaults?.set(now, forKey: wallKey); defaults?.set(uptime, forKey: uptimeKey) }
        guard let lastWall = defaults?.double(forKey: wallKey), lastWall > 0,
              let lastUptime = defaults?.double(forKey: uptimeKey) else { return false }
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
        if tampered { defaults?.set(true, forKey: tamperedKey) }
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
            if drift > 300 { defaults?.set(true, forKey: tamperedKey) }
        }.resume()
    }

    /// Whether the most recent check (from either the main app or the extension) found
    /// tampering — surfaced to the web UI so the person (and eventually their
    /// accountability partner) can see it happened, rather than it being silent.
    static func wasTamperedRecently() -> Bool {
        defaults?.bool(forKey: tamperedKey) ?? false
    }

    static func clearTamperFlag() {
        defaults?.set(false, forKey: tamperedKey)
    }
}
