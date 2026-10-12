import FamilyControls
import ManagedSettings
import SwiftUI

/* Per-app conditional blocking rules — the UI half of AppBlockingRules.swift. Native,
   not web, because Label(token) (Apple's own SwiftUI view for rendering a real app
   icon/name from an otherwise-opaque ApplicationToken) only exists in this framework;
   the web app never receives anything readable enough to build this screen itself. */

struct AppRuleListView: View {
    let tokens: [ApplicationToken]
    let onSave: (ApplicationToken, AppBlockRule) -> Void
    let onDone: () -> Void
    @State private var rules: [ApplicationToken: AppBlockRule] = AppBlockingRulesStore.shared.loadAll()

    var body: some View {
        NavigationView {
            List(tokens, id: \.self) { token in
                NavigationLink(destination: AppRuleEditView(
                    rule: rules[token] ?? AppBlockRule(),
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
    let onChange: (AppBlockRule) -> Void

    @State private var hasWindows: Bool
    @State private var hasBudget: Bool
    @State private var hasCooldown: Bool
    @State private var hasSessionLimit: Bool

    init(rule: AppBlockRule, onChange: @escaping (AppBlockRule) -> Void) {
        _rule = State(initialValue: rule)
        self.onChange = onChange
        _hasWindows = State(initialValue: !rule.unlockWindows.isEmpty)
        _hasBudget = State(initialValue: rule.budgetMinutes != nil)
        _hasCooldown = State(initialValue: rule.cooldownMinutes != nil)
        _hasSessionLimit = State(initialValue: rule.sessionLimitMinutes != nil)
    }

    var body: some View {
        Form {
            Section(footer: Text("Off: blocked all day, every day. On: only unlocked during times you set below.")) {
                Toggle("Unlock at specific times", isOn: $hasWindows.animation())
                    .onChange(of: hasWindows) { on in
                        if on, rule.unlockWindows.isEmpty { rule.unlockWindows = [TimeWindow(startMinute: 8*60, endMinute: 20*60)] }
                        if !on { rule.unlockWindows = []; hasBudget = false }
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
                        if rule.unlockWindows.isEmpty { hasWindows = false; hasBudget = false }
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
                            if !on { rule.budgetMinutes = nil; hasCooldown = false }
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

    private func commit() {
        rule.normalize()
        onChange(rule)
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
