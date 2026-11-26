import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI
import WebKit   // only for AppDelegate.shared?.webView?.evaluateJavaScript in logChange() below

/// Same escaping WebView.swift's own private jsStringLiteral() does — duplicated
/// rather than shared across files, it's a one-line helper with no state.
private func jsStringLiteral(_ s: String) -> String {
    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "'\(escaped)'"
}

/* App-level blocking (2026-10-11) — separate from and unrelated to DnsFilter.swift.
   DNS stays the mechanism for adult-content website blocking (the list never leaves
   the server, nobody has to look at it to turn blocking on/off — see DnsFilter.swift's
   own long comment for why that one is built the way it is). This file is only for
   blocking specific APPS (App Store first, any app the user picks later).

   Apple's Family Controls framework has exactly one way to let an app choose which
   apps/categories get restricted: FamilyActivityPicker, a system-provided SwiftUI view
   that must be shown to and completed BY A HUMAN — there is no API to hand Apple a list
   in the background. That's a real constraint for a website blocklist (which is why DNS
   is used there instead) but a non-issue here: app names aren't sensitive the way a
   website list is, so there's nothing to hide by using the real system picker.

   Everything the picker returns (ApplicationToken/ActivityCategoryToken) is already
   OPAQUE — Apple deliberately withholds the actual bundle identifier from the app even
   after selection, specifically so an app can't build a readable list of what someone
   blocked. FamilyActivitySelection itself is Codable, so it's persisted as-is (opaque
   tokens included) rather than trying to extract readable names out of it. */
final class AppBlocking {
    static let shared = AppBlocking()
    private let store = ManagedSettingsStore()
    private let center = DeviceActivityCenter()
    private let defaultsKey = "mtlogos.appBlockingSelection"
    private let appStoreBlockedKey = "mtlogos.appStoreBlocked"
    private let appStoreBundleID = "com.apple.AppStore"
    private let deletionBlockedKey = "mtlogos.deletionBlocked"

    /// One-tap App Store block (2026-10-11, Kanyon: "a toggle that blocks the app store").
    /// Deliberately a SEPARATE mechanism from the picker-based shield.applications above —
    /// Application(bundleIdentifier:) + store.application.blockedApplications is a real,
    /// distinct ManagedSettings API that works from a KNOWN bundle id with no picker
    /// involved at all (confirmed via Apple's own developer forum documentation before
    /// building this, after initially and WRONGLY telling Kanyon this wasn't possible —
    /// it blocks via the App Store's own well-known system bundle id, com.apple.AppStore,
    /// hides the app and prevents launching it, same as it would for any blocked app).
    /// This is strictly simpler than the shield mechanism: no token, no picker, no rule
    /// tiers — just on or off.
    /// 2026-10-12, real bug found in a security audit: this used to flip the UserDefaults
    /// flag AND the ManagedSettingsStore assignment with no Family Controls authorization
    /// check at all — ensureAuthorized() was only ever called from presentPicker() below.
    /// Anyone who toggled this on WITHOUT ever having opened the app-picker flow first
    /// (Screen Time authorization still .notDetermined) got a UI that said "blocked" and a
    /// UserDefaults flag that said true, while the actual ManagedSettingsStore assignment
    /// was a silent no-op — nothing enforced at all. Now requests authorization first, same
    /// as the picker path, and only commits the on-state (and reports success) once that's
    /// actually granted.
    func setAppStoreBlocked(_ on: Bool, completion: @escaping (Bool) -> Void) {
        guard on else {
            UserDefaults.standard.set(false, forKey: appStoreBlockedKey)
            store.application.blockedApplications = []
            completion(true)
            return
        }
        Task { @MainActor in
            guard await ensureAuthorized() else {
                completion(false)
                return
            }
            UserDefaults.standard.set(true, forKey: appStoreBlockedKey)
            store.application.blockedApplications = [Application(bundleIdentifier: appStoreBundleID)]
            completion(true)
        }
    }

    /// 2026-11-23, real report: "I don't think that feature is working right
    /// now" (about deletion-block, see isDeletionBlocked() below — same real
    /// gap exists here too). This used to just trust the local flag forever.
    /// If the person revokes Family Controls authorization in iOS Settings
    /// (a path Apple always exposes, same honest limit as everywhere else in
    /// this file), ManagedSettingsStore stops actually enforcing anything,
    /// but this kept reporting "Protected" regardless. Same real fix as
    /// DnsFilter.isEnabled()'s 2026-10-12 bug: stop trusting intent, check
    /// what's actually still true.
    func isAppStoreBlocked() -> Bool {
        let flagged = UserDefaults.standard.bool(forKey: appStoreBlockedKey)
        if flagged && !isScreenTimeAuthorized() {
            UserDefaults.standard.set(false, forKey: appStoreBlockedKey)
            return false
        }
        return flagged
    }

    /// Re-applies on every launch, same reasoning as reapplySavedShield() below — a
    /// plain UserDefaults flag doesn't re-apply the ManagedSettings change itself on
    /// its own, it just remembers what the person chose last.
    func reapplyAppStoreBlock() {
        if isAppStoreBlocked() {
            store.application.blockedApplications = [Application(bundleIdentifier: appStoreBundleID)]
        }
    }

    /// Deletion blocking (2026-10-30), Kanyon: "have you also added the toggle that
    /// makes it so the user cannot delete the mt logos app to bypass the blockers?" —
    /// real gap the comment at the top of block_edit_requests (worker/src/index.js)
    /// had flagged back on 2026-10-07 ("apps, sites, deletion-prevention... a later,
    /// separate piece") but this was never actually built, so until now simply
    /// deleting Mt. Logos bypassed both DnsFilter and the shield above completely.
    /// `Application.denyAppRemoval` is a real ManagedSettings property (iOS 16+, same
    /// Family Controls authorization already in use here, no new entitlement) —
    /// DEVICE-WIDE by design: Apple gives no way to protect just one app from
    /// deletion, only "deleting any app is off" as a whole. Turning it ON is free, same
    /// "no condition needed to add protection" rule as DnsFilter.enable()/the App
    /// Store block; turning it OFF is gated behind the SAME two-condition (partner
    /// approval + location) check as every other edit here — see "deletionBlocking" in
    /// WebView.swift and blockingCanEdit() in mtλapp.html — otherwise this toggle
    /// alone would let someone delete the app and walk straight around both blockers.
    func setDeletionBlocked(_ on: Bool, completion: @escaping (Bool) -> Void) {
        guard on else {
            UserDefaults.standard.set(false, forKey: deletionBlockedKey)
            store.application.denyAppRemoval = false
            completion(true)
            return
        }
        Task { @MainActor in
            guard await ensureAuthorized() else {
                completion(false)
                return
            }
            UserDefaults.standard.set(true, forKey: deletionBlockedKey)
            store.application.denyAppRemoval = true
            completion(true)
        }
    }

    /// 2026-11-23, REAL BUG, reported live: "Can you confirm that the app
    /// actually blocks uninstalling apps. i dont think that feature is
    /// working rn." Checked Apple's own developer forums first rather than
    /// guessing: denyAppRemoval under INDIVIDUAL (personal-device, non-MDM)
    /// Family Controls authorization is explicitly NOT guaranteed by Apple to
    /// prevent deletion once that authorization is revoked -- and the person
    /// can revoke it anytime in iOS Settings, a path this app has no way to
    /// block (same honest limit as DnsFilter.disable()'s own comment). This
    /// function only ever trusted the local flag it set, so it kept
    /// reporting "Protected" even after a revoked authorization had already
    /// silently stopped the real protection -- same bug class as
    /// DnsFilter.isEnabled()'s 2026-10-12 fix. Re-checking the real
    /// authorization here can't make denyAppRemoval itself more reliable
    /// (that ceiling is Apple's, not this app's), but it stops this toggle
    /// from lying about whether it's actually still in effect.
    func isDeletionBlocked() -> Bool {
        let flagged = UserDefaults.standard.bool(forKey: deletionBlockedKey)
        if flagged && !isScreenTimeAuthorized() {
            UserDefaults.standard.set(false, forKey: deletionBlockedKey)
            return false
        }
        return flagged
    }

    /// Re-applies on every launch, same reasoning as reapplyAppStoreBlock() above.
    func reapplyDeletionBlock() {
        if isDeletionBlocked() { store.application.denyAppRemoval = true }
    }

    /// Requests the Family Controls authorization prompt (the one system "Screen Time"
    /// permission dialog) if not already granted. Must happen before the picker can be
    /// shown — presenting FamilyActivityPicker without authorization just shows an empty,
    /// non-functional picker rather than erroring, so this is checked first on purpose.
    /// Not private any more (2026-11-16) — real report: a user who had only ever used
    /// DNS content blocking (a separate mechanism, no Family Controls involved) had NEVER
    /// been through this prompt at all, since it previously only fired lazily the first
    /// time the app-picker opened, and never found Mt. Logos in iOS's own Settings ->
    /// Screen Time -> "Apps With Screen Time Access" list as a result. Now also reachable
    /// directly via its own "Connect to Screen Time" button (see WebView.swift's
    /// "connectScreenTime" case), not just as a side effect of picking apps.
    ///
    /// 2026-11-18, real report: "it wasn't connecting or bringing up the popup... just
    /// inconsistent." This method is called from presentPicker()/the location flow/the
    /// Connect button, and nothing stopped two of those from calling it at the same
    /// moment (e.g. a second tap on the switch before the first round-trip finished).
    /// AuthorizationCenter's requestAuthorization has no documented behavior for being
    /// called twice while one call is already presenting its system sheet — a real,
    /// plausible way for the SECOND call to silently fail with no UI at all, which reads
    /// exactly like "didn't bring up the popup." Coalesce concurrent callers onto one
    /// in-flight Task instead of letting the framework see two simultaneous requests.
    private var authInFlight: Task<Bool, Never>?
    /// 2026-11-19, real report: a friend's real system Screen Time prompt kept
    /// reappearing "relentlessly" with no tap involved -- the actual loop turned
    /// out to be a web-side re-render polling the status check every 3 seconds
    /// (fixed in mtλapp.html's renderLayersSettings), but that bug living on the
    /// OTHER side of the bridge is exactly the kind of thing this side shouldn't
    /// have to trust never happens again. A flat cooldown between real
    /// AuthorizationCenter prompts is a hard backstop against ANY caller (a bug
    /// here, a bug on the web side, a future one neither side has thought of
    /// yet) ever looping this into a real system dialog faster than a human
    /// could plausibly be re-tapping the actual button. Short enough that a
    /// real "tap Connect, got denied, try again a few seconds later" still
    /// works; long enough that nothing resembling a loop ever reaches
    /// requestAuthorization a second time.
    private var lastAuthPromptAt: Date?
    private let authPromptCooldown: TimeInterval = 5
    func ensureAuthorized() async -> Bool {
        let center = AuthorizationCenter.shared
        if center.authorizationStatus == .approved { return true }
        if let inFlight = authInFlight { return await inFlight.value }
        if let last = lastAuthPromptAt, Date().timeIntervalSince(last) < authPromptCooldown {
            return false
        }
        lastAuthPromptAt = Date()
        let task = Task<Bool, Never> {
            do {
                try await center.requestAuthorization(for: .individual)
                return center.authorizationStatus == .approved
            } catch {
                return false
            }
        }
        authInFlight = task
        let result = await task.value
        authInFlight = nil
        return result
    }

    /// Read-only check, no prompt — lets the web page show "Connected"/"Not connected"
    /// on load without ever side-effecting a permission dialog just from rendering a tab.
    func isScreenTimeAuthorized() -> Bool {
        AuthorizationCenter.shared.authorizationStatus == .approved
    }

    private func loadSelection() -> FamilyActivitySelection {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return FamilyActivitySelection() }
        return decoded
    }

    private func saveSelection(_ selection: FamilyActivitySelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Applies (or re-applies) the shield for whatever is currently saved — called both
    /// right after the picker returns and once at launch, so a shield picked yesterday
    /// is still in force today without the user re-opening the picker.
    func reapplySavedShield() {
        ClockIntegrityGuard.checkAndRecord()
        let selection = loadSelection()
        applyShield(selection)
        LocationRuleMonitor.shared.sync()   // 2026-11-26: re-lift any app whose location rule currently allows it
    }

    /// Whether the clock looked tampered with on the most recent check (main app or the
    /// extension, whichever ran last) — see ClockIntegrityGuard's own header comment for
    /// the honest limits of what this can actually catch.
    func clockTamperDetected() -> Bool { ClockIntegrityGuard.wasTamperedRecently() }
    func clearClockTamperFlag() { ClockIntegrityGuard.clearTamperFlag() }

    /* 2026-11-24, Kanyon: picking an app now ONLY ADDS it. A newly picked app sits in the
       "pending" set (below) with no shield until he taps Save (or turns on Full block) in the
       rule editor. Pending apps are skipped here, both right after the picker and at every launch,
       so nothing is restricted before he has confirmed the settings. Apps picked before this
       update are never pending, so existing blocks are untouched. */
    private let pendingKey = "mtlogos.appBlockingPendingTokens"
    func loadPending() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
    }
    private func savePending(_ s: Set<String>) {
        UserDefaults.standard.set(Array(s), forKey: pendingKey)
    }
    func isPending(_ token: ApplicationToken) -> Bool { loadPending().contains(tokenB64(token)) }
    private func confirmPending(_ token: ApplicationToken) {
        var p = loadPending(); p.remove(tokenB64(token)); savePending(p)
    }

    private func applyShield(_ selection: FamilyActivitySelection) {
        let pending = loadPending()
        let shielded = selection.applicationTokens.filter { !pending.contains(tokenB64($0)) }
        store.shield.applications = shielded.isEmpty ? nil : shielded
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens, except: [])
    }

    /// Fire-and-forget: tells the web app's log (and, through it, the server) that a
    /// loosening change just happened — see mtλapp.html's __blockLogChange and
    /// worker/src/index.js's /api/blocking/log-change, which silently ignores this if
    /// there's no currently-approved window to attach it to (the normal case for a
    /// tightening change). Only ever called for the loosening direction, same
    /// principle as every other call site of this in mtλapp.html.
    private func logChange(_ action: String, _ detail: String) {
        let js = "window.__blockLogChange && window.__blockLogChange(" + jsStringLiteral(action) + "," + jsStringLiteral(detail) + ")"
        DispatchQueue.main.async { AppDelegate.shared?.webView?.evaluateJavaScript(js) }
    }

    /// Requests authorization (if needed) and presents the real system app picker modally
    /// over whatever view controller is on screen. On Done, chains straight into the rule
    /// editor for whatever's now selected (newly-added apps start fully blocked, Kanyon's
    /// stated default, until a rule is actually set for them) — completion only fires once
    /// that whole flow (picker + rule editor) is dismissed. completion gets (ok, appCount, error).
    ///
    /// canEdit (2026-10-30): picking apps is always allowed — ADDING a new blocked app
    /// is tightening, same "no condition needed to add more accountability" rule as
    /// every binary toggle in this file. REMOVING an already-blocked app is the
    /// loosening half; when canEdit is false, any token/category present in the OLD
    /// selection but missing from what the picker returned is silently added back in
    /// before saving, so the picker can never be used to quietly un-block something
    /// without the partner gate mtλapp.html already checked before calling this.
    func presentPicker(from vc: UIViewController, canEdit: Bool, completion: @escaping (Bool, Int, String?) -> Void) {
        Task { @MainActor in
            guard await ensureAuthorized() else {
                completion(false, 0, "Screen Time permission was not granted.")
                return
            }
            let oldSelection = self.loadSelection()
            let picker = AppBlockPickerView(
                initial: oldSelection,
                onDone: { [weak self] pickerResult in
                    guard let self else { return }
                    var finalSelection = pickerResult
                    // Pending (not yet blocked) apps can be dropped freely: removing something that was
                    // never blocked is not a loosening, so only really-blocked apps count here.
                    let pendingBefore = self.loadPending()
                    let removedApps = oldSelection.applicationTokens
                        .subtracting(pickerResult.applicationTokens)
                        .filter { !pendingBefore.contains(self.tokenB64($0)) }
                    // Newly picked apps are ADDED only: pending, no shield until confirmed in the editor.
                    let newlyAdded = pickerResult.applicationTokens.subtracting(oldSelection.applicationTokens)
                    var pendingNow = pendingBefore.union(newlyAdded.map { self.tokenB64($0) })
                    let removedCats = oldSelection.categoryTokens.subtracting(pickerResult.categoryTokens)
                    let blockedRemoval = !canEdit && (!removedApps.isEmpty || !removedCats.isEmpty)
                    if blockedRemoval {
                        finalSelection.applicationTokens = pickerResult.applicationTokens.union(removedApps)
                        finalSelection.categoryTokens = pickerResult.categoryTokens.union(removedCats)
                    }
                    // Forget pending marks for apps that are no longer selected at all.
                    let keptB64 = Set(finalSelection.applicationTokens.map { self.tokenB64($0) })
                    pendingNow = pendingNow.intersection(keptB64)
                    self.savePending(pendingNow)
                    self.saveSelection(finalSelection)
                    self.applyShield(finalSelection)
                    self.pruneRulesToSelection(finalSelection)
                    let allowedRemoval = canEdit && (!removedApps.isEmpty || !removedCats.isEmpty)
                    vc.dismiss(animated: true) {
                        // Adding apps is tightening — never logged, see logChange's own comment.
                        if allowedRemoval {
                            let n = removedApps.count + removedCats.count
                            self.logChange("apps_removed", n == 1 ? "1 app/category" : "\(n) apps/categories")
                        }
                        self.presentRuleEditor(from: vc, canEdit: canEdit) { _ in
                            completion(true, finalSelection.applicationTokens.count + finalSelection.categoryTokens.count, nil)
                        }
                    }
                },
                onCancel: {
                    vc.dismiss(animated: true) {
                        completion(false, 0, nil)
                    }
                }
            )
            let hosting = UIHostingController(rootView: picker)
            vc.present(hosting, animated: true)
        }
    }

    /// Presents the native per-app rule editor (unlock windows -> budget -> cooldown ->
    /// session limit, in that exact order — see AppBlockingRules.swift) for whatever apps
    /// are currently selected. Has to be native SwiftUI, not the web app: Label(token) is
    /// the only thing that can show a real name/icon for an opaque ApplicationToken, and
    /// that capability doesn't exist outside Apple's own frameworks. canEdit is passed
    /// straight through to AppRuleEditView, which does the actual tighten/loosen
    /// enforcement per edit (see its own commit()).
    func presentRuleEditor(from vc: UIViewController, canEdit: Bool, completion: @escaping (Bool) -> Void) {
        let selection = loadSelection()
        guard !selection.applicationTokens.isEmpty else { completion(true); return }
        let editor = AppRuleListView(
            tokens: Array(selection.applicationTokens),
            canEdit: canEdit,
            pendingTokens: Set(selection.applicationTokens.filter { isPending($0) }),
            onConfirm: { [weak self] token, rule in
                // Save / Full block tapped on a newly added app: NOW it gets its rule and shield.
                guard let self else { return }
                self.applyRule(rule, for: token)
                self.confirmPending(token)
                LocationRuleMonitor.shared.sync()
            },
            onSave: { [weak self] token, rule in
                guard let self else { return }
                let old = AppBlockingRulesStore.shared.rule(for: token)
                self.applyRule(rule, for: token)
                LocationRuleMonitor.shared.sync()
                // AppRuleEditView already only lets a loosening edit through when
                // canEdit is true (reverting it otherwise) — this just decides whether
                // what DID land is worth telling the partner about.
                // 2026-11-16: detail now carries the real before/after numbers (e.g.
                // "daily budget 60 to 90 min") instead of always being empty — the app's
                // NAME still can never be included (ApplicationToken is Apple-opaque,
                // no API anywhere resolves it back to "Instagram"), but the actual
                // numbers changed are available right here and were simply never passed
                // through before.
                if !appBlockRuleIsTighterOrEqual(from: old, to: rule) {
                    self.logChange("rule_loosened", describeRuleLoosening(from: old, to: rule))
                }
            },
            onDone: {
                vc.dismiss(animated: true) { completion(true) }
            }
        )
        let hosting = UIHostingController(rootView: editor)
        vc.present(hosting, animated: true)
    }

    /// Drops any saved rule (and stops its monitoring) for a token no longer in the
    /// current selection — otherwise a removed app's old schedule would keep firing
    /// against a token nothing shields anymore.
    private func pruneRulesToSelection(_ selection: FamilyActivitySelection) {
        let kept = selection.applicationTokens
        var all = AppBlockingRulesStore.shared.loadAll()
        for token in all.keys where !kept.contains(token) {
            stopMonitoring(for: token)
            all.removeValue(forKey: token)
        }
        AppBlockingRulesStore.shared.saveAll(all)
    }

    private func tokenB64(_ token: ApplicationToken) -> String {
        (try? JSONEncoder().encode(token))?.base64EncodedString() ?? "x"
    }

    private func activityName(_ kind: String, token: ApplicationToken, index: Int = 0) -> DeviceActivityName {
        DeviceActivityName(kind + "|" + tokenB64(token) + "|" + String(index))
    }

    private func stopMonitoring(for token: ApplicationToken) {
        let mine = center.activities.filter { $0.rawValue.contains("|" + tokenB64(token) + "|") }
        if !mine.isEmpty { center.stopMonitoring(mine) }
    }

    /// The real enforcement wiring for one app's rule — see MonitorExtension.swift for
    /// what actually responds to the schedules/events registered here, and its header
    /// comment for the honest limits of mapping cooldown/session concepts onto
    /// DeviceActivity's cumulative-usage/calendar-interval primitives. Starts the app
    /// shielded unconditionally (matches "blocked by default"); a schedule only ever
    /// LIFTS that default, never the other way around, which keeps the fallback state
    /// always on the safe (blocked) side if anything here fails to register.
    func applyRule(_ rule: AppBlockRule, for token: ApplicationToken) {
        AppBlockingRulesStore.shared.setRule(rule, for: token)
        stopMonitoring(for: token)

        var apps = store.shield.applications ?? []
        apps.insert(token)
        store.shield.applications = apps

        guard !rule.isFullyBlocked else { return }

        for (i, window) in rule.unlockWindows.enumerated() {
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: window.startMinute / 60, minute: window.startMinute % 60),
                intervalEnd: DateComponents(hour: window.endMinute / 60, minute: window.endMinute % 60),
                repeats: true
            )
            try? center.startMonitoring(activityName("window", token: token, index: i), during: schedule, events: [:])
        }

        guard let budget = rule.budgetMinutes else { return }
        // Week-period budgets use a weekday-bounded interval (Sunday through Saturday)
        // instead of a plain daily repeat — this is the single most uncertain piece of
        // scheduling logic in this whole feature and needs real device verification
        // before trusting it resets exactly on the week boundary as intended.
        let span: DeviceActivitySchedule = rule.budgetPeriod == .week
            ? DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0, weekday: 1),
                                      intervalEnd: DateComponents(hour: 23, minute: 59, weekday: 7), repeats: true)
            : DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                      intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [
            DeviceActivityEvent.Name("budget"): DeviceActivityEvent(applications: [token], threshold: DateComponents(minute: budget))
        ]
        if let session = rule.sessionLimitMinutes {
            events[DeviceActivityEvent.Name("session")] = DeviceActivityEvent(applications: [token], threshold: DateComponents(minute: session))
        }
        try? center.startMonitoring(activityName("budget", token: token), during: span, events: events)
    }

    /// Removes the shield entirely and forgets the saved selection — a real, working
    /// "turn it off" path, same honest limit as DnsFilter.disable(): this is the
    /// accountability-via-honesty model throughout the app, not a tamper-proof lock.
    func clear(completion: @escaping (Bool) -> Void) {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: pendingKey)
        completion(true)
    }

    /// (isActive, count) — count is apps + categories selected, not resolvable to names
    /// (see the opaque-token note above), just enough for the page to show "N blocked."
    func status() -> (Bool, Int) {
        let selection = loadSelection()
        let count = selection.applicationTokens.count + selection.categoryTokens.count
        return (count > 0, count)
    }
}

private struct AppBlockPickerView: View {
    @State var selection: FamilyActivitySelection
    let onDone: (FamilyActivitySelection) -> Void
    let onCancel: () -> Void

    init(initial: FamilyActivitySelection, onDone: @escaping (FamilyActivitySelection) -> Void, onCancel: @escaping () -> Void) {
        _selection = State(initialValue: initial)
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationView {
            FamilyActivityPicker(selection: $selection)
                .navigationTitle("Choose apps to block")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onCancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDone(selection) }
                    }
                }
        }
    }
}
