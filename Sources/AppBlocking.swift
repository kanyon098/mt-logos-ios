import FamilyControls
import ManagedSettings
import SwiftUI

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
    private let defaultsKey = "mtlogos.appBlockingSelection"

    /// Requests the Family Controls authorization prompt (the one system "Screen Time"
    /// permission dialog) if not already granted. Must happen before the picker can be
    /// shown — presenting FamilyActivityPicker without authorization just shows an empty,
    /// non-functional picker rather than erroring, so this is checked first on purpose.
    private func ensureAuthorized() async -> Bool {
        let center = AuthorizationCenter.shared
        if center.authorizationStatus == .approved { return true }
        do {
            try await center.requestAuthorization(for: .individual)
            return center.authorizationStatus == .approved
        } catch {
            return false
        }
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
        let selection = loadSelection()
        applyShield(selection)
    }

    private func applyShield(_ selection: FamilyActivitySelection) {
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens, except: [])
    }

    /// Requests authorization (if needed) and presents the real system app picker modally
    /// over whatever view controller is on screen. completion gets (ok, appCount, error).
    func presentPicker(from vc: UIViewController, completion: @escaping (Bool, Int, String?) -> Void) {
        Task { @MainActor in
            guard await ensureAuthorized() else {
                completion(false, 0, "Screen Time permission was not granted.")
                return
            }
            let picker = AppBlockPickerView(
                initial: self.loadSelection(),
                onDone: { [weak self] selection in
                    guard let self else { return }
                    self.saveSelection(selection)
                    self.applyShield(selection)
                    vc.dismiss(animated: true) {
                        completion(true, selection.applicationTokens.count + selection.categoryTokens.count, nil)
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

    /// Removes the shield entirely and forgets the saved selection — a real, working
    /// "turn it off" path, same honest limit as DnsFilter.disable(): this is the
    /// accountability-via-honesty model throughout the app, not a tamper-proof lock.
    func clear(completion: @escaping (Bool) -> Void) {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
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
