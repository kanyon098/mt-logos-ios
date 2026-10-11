import FamilyControls
import Foundation

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

    private func tokenKey(_ token: ApplicationToken) -> String {
        guard let data = try? JSONEncoder().encode(token) else { return "unknown" }
        return data.base64EncodedString()
    }
}
