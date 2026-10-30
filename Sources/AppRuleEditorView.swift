import FamilyControls
import ManagedSettings
import SwiftUI

/* Per-app conditional blocking rules — the UI half of AppBlockingRules.swift. Native,
   not web, because Label(token) (Apple's own SwiftUI view for rendering a real app
   icon/name from an otherwise-opaque ApplicationToken) only exists in this framework;
   the web app never receives anything readable enough to build this screen itself. */

struct AppRuleListView: View {
    let tokens: [ApplicationToken]
    /// 2026-10-30, Kanyon: "you should be able to make any blocking more tight while
    /// the block is active, but not less tight unless the partner unlocks it." When
    /// false, AppRuleEditView still lets every tightening edit through — it only
    /// reverts (and warns about) an edit that would loosen the rule below what it
    /// already was. See appBlockRuleIsTighterOrEqual() in AppBlockingRules.swift.
    let canEdit: Bool
    let onSave: (ApplicationToken, AppBlockRule) -> Void
    let onDone: () -> Void
    @State private var rules: [ApplicationToken: AppBlockRule] = AppBlockingRulesStore.shared.loadAll()

    var body: some View {
        NavigationView {
            List(tokens, id: \.self) { token in
                NavigationLink(destination: AppRuleEditView(
                    rule: rules[token] ?? AppBlockRule(),
                    canEdit: canEdit,
                    onChange: { newRule in
                        rules[token] = newRule
                        onSave(token, newRule)
                    }
                )) {
                    HStack {
                        Label(token)
                        Spacer()
                        Text(summary(for: rules[token] ?? AppBlockRule()))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Blocking rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
    }

    private func summary(for rule: AppBlockRule) -> String {
        if rule.isFullyBlocked { return "Blocked" }
        if rule.sessionLimitMinutes != nil { return "Scheduled, limited" }
        if rule.cooldownMinutes != nil { return "Scheduled, cooldown" }
        if rule.budgetMinutes != nil { return "Scheduled, budget" }
        return "Scheduled"
    }
}

/// The four tiers, always in this order, each only enabled once the one above it is on
/// — Kanyon's exact spec: "default is fully block and then from there you can say
/// unlock at these times. Then... total time allotted per day or per week. And
/// then... how much time between opens. And then... how long a session can be."
struct AppRuleEditView: View {
    @State var rule: AppBlockRule
    let canEdit: Bool
    let onChange: (AppBlockRule) -> Void

    /// The last rule that was actually either tighter-or-equal, or explicitly allowed
    /// because canEdit was true at the time — what an invalid (loosening, !canEdit)
    /// edit reverts back to. See commit() below.
    @State private var lastGoodRule: AppBlockRule
    @State private var warning: String? = nil

    @State private var hasWindows: Bool
    @State private var hasBudget: Bool
    @State private var hasCooldown: Bool
    @State private var hasSessionLimit: Bool

    init(rule: AppBlockRule, canEdit: Bool, onChange: @escaping (AppBlockRule) -> Void) {
        _rule = State(initialValue: rule)
        self.canEdit = canEdit
        self.onChange = onChange
        _lastGoodRule = State(initialValue: rule)
        _hasWindows = State(initialValue: !rule.unlockWindows.isEmpty)
        _hasBudget = State(initialValue: rule.budgetMinutes != nil)
        _hasCooldown = State(initialValue: rule.cooldownMinutes != nil)
        _hasSessionLimit = State(initialValue: rule.sessionLimitMinutes != nil)
    }

    var body: some View {
        Form {
            if let warning {
                Section { Text(warning).font(.caption).foregroundColor(.red) }
            }
            Section(footer: Text("Off: blocked all day, every day. On: only unlocked during times you set below.")) {
                Toggle("Unlock at specific times", isOn: $hasWindows.animation())
                    .onChange(of: hasWindows) { on in
                        if on, rule.unlockWindows.isEmpty { rule.unlockWindows = [TimeWindow(startMinute: 8*60, endMinute: 20*60)] }
                        /* 2026-10-12, real bug found in a fresh audit pass: turning a
                           tier off only ever reset the NEXT @State flag, never
                           anything deeper — rule.normalize() (called via commit()
                           below) correctly cascade-clears the underlying AppBlockRule
                           struct all the way down, but these UI booleans gating which
                           sections render didn't follow. Concretely: configure all 4
                           tiers, turn "Unlock at specific times" off then back on —
                           hasSessionLimit could still read true from before even
                           though rule.sessionLimitMinutes is now really nil, so the
                           toggle renders already "on" with a stale minutes value and
                           SwiftUI's onChange never fires to fix it (the boolean never
                           actually changed). The person believes a safeguard is
                           configured when it silently isn't — the exact failure mode
                           this whole feature exists to prevent. Now resets every
                           deeper flag, not just the adjacent one. */
                        if !on { rule.unlockWindows = []; hasBudget = false; hasCooldown = false; hasSessionLimit = false }
                        commit()
                    }
            }

            if hasWindows {
                Section("Unlock windows") {
                    ForEach(rule.unlockWindows.indices, id: \.self) { i in
                        TimeWindowRow(window: $rule.unlockWindows[i], onChange: commit)
                    }
                    .onDelete { idx in
                        rule.unlockWindows.remove(atOffsets: idx)
                        // Same cascade-reset fix as the toggle above.
                        if rule.unlockWindows.isEmpty { hasWindows = false; hasBudget = false; hasCooldown = false; hasSessionLimit = false }
                        commit()
                    }
                    Button("+ Add another window") {
                        rule.unlockWindows.append(TimeWindow(startMinute: 8*60, endMinute: 20*60))
                        commit()
                    }
                }

                Section(footer: Text("Total time this app can be open, within your unlock windows.")) {
                    Toggle("Limit total time", isOn: $hasBudget.animation())
                        .onChange(of: hasBudget) { on in
                            if on, rule.budgetMinutes == nil { rule.budgetMinutes = 60 }
                            // Same cascade-reset fix as hasWindows above.
                            if !on { rule.budgetMinutes = nil; hasCooldown = false; hasSessionLimit = false }
                            commit()
                        }
                }

                if hasBudget {
                    Section("Time budget") {
                        Stepper("\(rule.budgetMinutes ?? 60) minutes", value: Binding(
                            get: { rule.budgetMinutes ?? 60 },
                            set: { rule.budgetMinutes = $0; commit() }
                        ), in: 5...600, step: 5)
                        Picker("Per", selection: Binding(
                            get: { rule.budgetPeriod },
                            set: { rule.budgetPeriod = $0; commit() }
                        )) {
                            Text("Day").tag(BudgetPeriod.day)
                            Text("Week").tag(BudgetPeriod.week)
                        }.pickerStyle(.segmented)
                    }

                    Section(footer: Text("How long to wait after closing it before it can be opened again.")) {
                        Toggle("Require a gap between opens", isOn: $hasCooldown.animation())
                            .onChange(of: hasCooldown) { on in
                                if on, rule.cooldownMinutes == nil { rule.cooldownMinutes = 15 }
                                if !on { rule.cooldownMinutes = nil; hasSessionLimit = false }
                                commit()
                            }
                    }

                    if hasCooldown {
                        Section("Cooldown") {
                            Stepper("\(rule.cooldownMinutes ?? 15) minutes between opens", value: Binding(
                                get: { rule.cooldownMinutes ?? 15 },
                                set: { rule.cooldownMinutes = $0; commit() }
                            ), in: 1...240, step: 1)
                        }

                        Section(footer: Text("Locks the app automatically after this many minutes in one sitting — breaks up long scrolling sessions.")) {
                            Toggle("Limit session length", isOn: $hasSessionLimit.animation())
                                .onChange(of: hasSessionLimit) { on in
                                    if on, rule.sessionLimitMinutes == nil { rule.sessionLimitMinutes = 10 }
                                    if !on { rule.sessionLimitMinutes = nil }
                                    commit()
                                }
                        }

                        if hasSessionLimit {
                            Section("Session limit") {
                                Stepper("\(rule.sessionLimitMinutes ?? 10) minutes per sitting", value: Binding(
                                    get: { rule.sessionLimitMinutes ?? 10 },
                                    set: { rule.sessionLimitMinutes = $0; commit() }
                                ), in: 1...120, step: 1)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("App rules")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 2026-10-30, Kanyon: "you should be able to make any blocking more tight while
    /// the block is active, but not less tight unless the partner unlocks it." Every
    /// control above already mutates `rule` (and the matching has* flag) before
    /// calling this — if the result loosens anything relative to lastGoodRule and
    /// canEdit is false, it's reverted right back (UI snaps to where it was, with a
    /// reason) instead of silently taking effect.
    private func commit() {
        rule.normalize()
        if !canEdit && !appBlockRuleIsTighterOrEqual(from: lastGoodRule, to: rule) {
            warning = "That loosens this app’s rule — ask your accountability partner for the usual 10 minutes first."
            rule = lastGoodRule
            syncTogglesToRule()
            return
        }
        warning = nil
        lastGoodRule = rule
        onChange(rule)
    }

    /// Keeps the four progressive-disclosure toggles in sync after commit() reverts
    /// `rule` — otherwise a toggle could keep reading "on" with a value the struct no
    /// longer actually has, the exact stale-flag bug already fixed once in this file
    /// (see the "Unlock at specific times" toggle's own 2026-10-12 comment below).
    private func syncTogglesToRule() {
        hasWindows = !rule.unlockWindows.isEmpty
        hasBudget = rule.budgetMinutes != nil
        hasCooldown = rule.cooldownMinutes != nil
        hasSessionLimit = rule.sessionLimitMinutes != nil
    }
}

private struct TimeWindowRow: View {
    @Binding var window: TimeWindow
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                /// 2026-10-12, real self-lock bug found in a security audit:
                /// AppBlockingRules.swift's own comment states the invariant
                /// "endMinute must be > startMinute; overnight windows aren't
                /// supported in v1," but nothing here ever enforced it — nothing
                /// stopped someone from setting "To" earlier than "From" (a very
                /// plausible real action for anyone trying an overnight window like
                /// "unlock 10pm-6am," since nothing in the UI hints that isn't
                /// supported). That malformed window reaches
                /// AppBlocking.applyRule()'s `try? center.startMonitoring(...)`,
                /// which silently fails or registers a degenerate interval — either
                /// way the app stays shielded by default (the documented fallback)
                /// with no schedule that ever actually lifts it, while the rule list
                /// still shows "Scheduled" as if it worked. Fixed by clamping
                /// instead of just documenting the invariant: setting either end of
                /// the window now keeps End > Start automatically, same-day only,
                /// so the invalid state this bug depended on can no longer be saved.
                DatePicker("From", selection: Binding(
                    get: { Self.date(fromMinute: window.startMinute) },
                    set: { newDate in
                        let newStart = Self.minute(from: newDate)
                        window.startMinute = newStart
                        if window.endMinute <= newStart { window.endMinute = min(newStart + 1, 23*60+59) }
                        onChange()
                    }
                ), displayedComponents: .hourAndMinute).labelsHidden()
                Text("to")
                DatePicker("To", selection: Binding(
                    get: { Self.date(fromMinute: window.endMinute) },
                    set: { newDate in
                        var newEnd = Self.minute(from: newDate)
                        if newEnd <= window.startMinute { newEnd = min(window.startMinute + 1, 23*60+59) }
                        window.endMinute = newEnd
                        onChange()
                    }
                ), displayedComponents: .hourAndMinute).labelsHidden()
            }
            Text("Same day only — this can't cross midnight yet.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private static func date(fromMinute m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minute(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
