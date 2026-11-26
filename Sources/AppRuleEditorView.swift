import CoreLocation
import FamilyControls
import ManagedSettings
import MapKit
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
    /// 2026-11-24: apps that were just added and are NOT blocked yet. They show "Not blocked yet" and
    /// only get a rule (and a shield) when Save or Full block is confirmed in their editor.
    let pendingTokens: Set<ApplicationToken>
    let onConfirm: (ApplicationToken, AppBlockRule) -> Void
    let onSave: (ApplicationToken, AppBlockRule) -> Void
    let onDone: () -> Void
    @State private var rules: [ApplicationToken: AppBlockRule] = AppBlockingRulesStore.shared.loadAll()
    @State private var stillPending: Set<ApplicationToken> = []

    var body: some View {
        NavigationView {
            List(tokens, id: \.self) { token in
                NavigationLink(destination: AppRuleEditView(
                    rule: rules[token] ?? AppBlockRule(),
                    canEdit: canEdit,
                    isPending: stillPending.contains(token),
                    onConfirm: { confirmed in
                        rules[token] = confirmed
                        stillPending.remove(token)
                        onConfirm(token, confirmed)
                    },
                    onChange: { newRule in
                        rules[token] = newRule
                        onSave(token, newRule)
                    }
                )) {
                    HStack {
                        Label(token)
                        Spacer()
                        Text(summary(for: rules[token] ?? AppBlockRule(), token: token))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onAppear { if stillPending.isEmpty { stillPending = pendingTokens } }
            .navigationTitle("Blocking rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
    }

    private func summary(for rule: AppBlockRule, token: ApplicationToken? = nil) -> String {
        if let token, stillPending.contains(token) { return "Not blocked yet" }
        if rule.isFullyBlocked { return "Blocked" }
        if rule.location != nil { return rule.unlockWindows.isEmpty ? "Location only" : "Scheduled + location" }
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
    /// True for an app that was just added and is not blocked yet. In that mode nothing is applied
    /// while he edits (commit() does not call onChange); Save / Full block calls onConfirm once.
    let onConfirm: (AppBlockRule) -> Void
    let onChange: (AppBlockRule) -> Void
    @State private var isPending: Bool
    @State private var fullBlock: Bool = false

    /// The last rule that was actually either tighter-or-equal, or explicitly allowed
    /// because canEdit was true at the time — what an invalid (loosening, !canEdit)
    /// edit reverts back to. See commit() below.
    @State private var lastGoodRule: AppBlockRule
    @State private var warning: String? = nil

    @State private var hasWindows: Bool
    @State private var hasBudget: Bool
    @State private var hasCooldown: Bool
    @State private var hasSessionLimit: Bool
    // 2026-11-26: per-app location rule (see LocationRule in AppBlockingRules.swift).
    @State private var hasLocation: Bool
    @State private var distanceText: String? = nil

    init(rule: AppBlockRule, canEdit: Bool, isPending: Bool = false, onConfirm: @escaping (AppBlockRule) -> Void = { _ in }, onChange: @escaping (AppBlockRule) -> Void) {
        _rule = State(initialValue: rule)
        self.canEdit = canEdit
        _isPending = State(initialValue: isPending)
        self.onConfirm = onConfirm
        self.onChange = onChange
        _lastGoodRule = State(initialValue: rule)
        _hasWindows = State(initialValue: !rule.unlockWindows.isEmpty)
        _hasBudget = State(initialValue: rule.budgetMinutes != nil)
        _hasCooldown = State(initialValue: rule.cooldownMinutes != nil)
        _hasSessionLimit = State(initialValue: rule.sessionLimitMinutes != nil)
        _hasLocation = State(initialValue: rule.location != nil)
    }

    var body: some View {
        Form {
            if let warning {
                Section { Text(warning).font(.caption).foregroundColor(.red) }
            }
            if isPending {
                Section(footer: Text("Not blocked yet. Turn on Full block, or set times and limits below, then tap Save. Nothing is restricted until you do.")) {
                    Toggle("Full block", isOn: $fullBlock.animation())
                        .onChange(of: fullBlock) { on in
                            if on {
                                rule = AppBlockRule()
                                hasWindows = false; hasBudget = false; hasCooldown = false; hasSessionLimit = false; hasLocation = false
                            }
                        }
                    Button("Save") {
                        rule.normalize()
                        onConfirm(rule)
                        lastGoodRule = rule
                        isPending = false
                    }
                    .disabled(!(fullBlock || hasWindows || rule.location != nil))
                }
            }
            Section(footer: Text("Off: blocked all day, every day (unless a location rule below decides). On: only unlocked during times you set below.")) {
                Toggle("Unlock at specific times", isOn: $hasWindows.animation())
                    .onChange(of: hasWindows) { on in
                        if on, rule.unlockWindows.isEmpty { rule.unlockWindows = [TimeWindow(startMinute: 8*60, endMinute: 20*60)] }
                        if on { fullBlock = false }
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

            // 2026-11-26, Kanyon: a map rule per app. COMBINES with the times above as AND: the app opens only when the
            // time rule allows AND the location rule allows. No times set = no time limit, location alone decides.
            Section(footer: Text(locationFooter)) {
                Toggle("Location rule", isOn: $hasLocation.animation())
                    .onChange(of: hasLocation) { on in
                        if on {
                            fullBlock = false
                            useMyLocation()
                        } else {
                            rule.location = nil
                            distanceText = nil
                            commit()
                        }
                    }
            }
            if hasLocation {
                Section("Location") {
                    Picker("Inside the circle", selection: Binding(
                        get: { rule.location?.allowInside ?? true },
                        set: { v in if var l = rule.location { l.allowInside = v; rule.location = l; commit() } }
                    )) {
                        Text("App allowed").tag(true)
                        Text("App blocked").tag(false)
                    }.pickerStyle(.segmented)
                    RuleMapPicker(
                        coordinate: rule.location.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) },
                        radius: rule.location?.radiusMeters ?? 500,
                        onPick: { c in setPin(c) }
                    )
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                    Button("Use my current location") { useMyLocation() }
                    if let loc = rule.location {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Radius: \(Self.radiusText(loc.radiusMeters))")
                            Slider(value: Binding(
                                get: { loc.radiusMeters },
                                set: { v in if var l = rule.location { l.radiusMeters = v; rule.location = l } }
                            ), in: 100...5000, step: 50, onEditingChanged: { editing in if !editing { commit() } })
                        }
                        if let distanceText { Text(distanceText).font(.caption).foregroundColor(.secondary) }
                    } else {
                        Text("Press and hold on the map to drop a pin.").font(.caption).foregroundColor(.secondary)
                    }
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

    private var locationFooter: String {
        var s = "Pick a place and a radius: inside it this app is either allowed or blocked. It works together with the times above: the app opens only when BOTH allow."
        if !LocationRuleMonitor.shared.hasAlwaysAccess {
            s += " To work while Mt. Logos is closed, set Location to Always in iPhone Settings > Mt. Logos > Location. Until then the app stays blocked."
        }
        return s
    }

    private static func radiusText(_ meters: Double) -> String {
        let feet = meters * 3.28084
        if feet < 1000 { return "\(Int((feet / 10).rounded()) * 10) ft" }
        return String(format: "%.1f mi", meters / 1609.34)
    }

    private func setPin(_ c: CLLocationCoordinate2D) {
        var l = rule.location ?? LocationRule(lat: c.latitude, lng: c.longitude, radiusMeters: 500, allowInside: true)
        l.lat = c.latitude
        l.lng = c.longitude
        rule.location = l
        commit()
        refreshDistance()
    }

    private func useMyLocation() {
        Task { @MainActor in
            if let here = await BlockLocation.shared.currentCoordinate() {
                setPin(CLLocationCoordinate2D(latitude: here.lat, longitude: here.lng))
            }
        }
    }

    private func refreshDistance() {
        guard let loc = rule.location else { distanceText = nil; return }
        Task { @MainActor in
            if let mi = await BlockLocation.shared.distanceMiles(toLat: loc.lat, lng: loc.lng) {
                distanceText = mi < 0.1 ? "You are at this pin." : String(format: "You are %.1f mi from this pin.", mi)
            } else {
                distanceText = nil
            }
        }
    }

    /// 2026-10-30, Kanyon: "you should be able to make any blocking more tight while
    /// the block is active, but not less tight unless the partner unlocks it." Every
    /// control above already mutates `rule` (and the matching has* flag) before
    /// calling this — if the result loosens anything relative to lastGoodRule and
    /// canEdit is false, it's reverted right back (UI snaps to where it was, with a
    /// reason) instead of silently taking effect.
    private func commit() {
        rule.normalize()
        // Newly added app: a brand-new app has nothing to loosen, and nothing is applied until Save.
        if isPending { warning = nil; return }
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
        hasLocation = rule.location != nil
    }
}

/// Small MapKit picker: press and hold drops the pin, a circle shows the radius. Plain Apple MapKit, no paid service.
private struct RuleMapPicker: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D?
    let radius: Double
    let onPick: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.4
        map.addGestureRecognizer(press)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onPick = onPick
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        guard let c = coordinate else { return }
        let pin = MKPointAnnotation()
        pin.coordinate = c
        map.addAnnotation(pin)
        map.addOverlay(MKCircle(center: c, radius: radius))
        if !context.coordinator.didCenter || context.coordinator.lastCenter.map({ abs($0.latitude - c.latitude) > 1e-6 || abs($0.longitude - c.longitude) > 1e-6 }) ?? true {
            let span = max(radius * 4, 800)
            map.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: span, longitudinalMeters: span), animated: false)
            context.coordinator.didCenter = true
            context.coordinator.lastCenter = c
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onPick: (CLLocationCoordinate2D) -> Void
        var didCenter = false
        var lastCenter: CLLocationCoordinate2D?
        init(onPick: @escaping (CLLocationCoordinate2D) -> Void) { self.onPick = onPick }

        @objc func pressed(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MKMapView else { return }
            onPick(map.convert(g.location(in: map), toCoordinateFrom: map))
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKCircleRenderer(circle: circle)
            r.strokeColor = UIColor.systemGreen
            r.fillColor = UIColor.systemGreen.withAlphaComponent(0.15)
            r.lineWidth = 2
            return r
        }
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
