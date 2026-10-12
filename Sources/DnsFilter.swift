import NetworkExtension

/* Content blocking (2026-10-08) — see worker/src/index.js's "/dns-query" route for
   the server half and its own long comment for why DNS, specifically, is the one
   mechanism that works on a normal personal iPhone: no Family Controls picker (which
   would force exposing the block list to whoever picks), no Network Extension content
   filter (which Apple restricts to supervised/managed devices, never a personal one).

   NEDNSSettingsManager needs no special entitlement — it's the same public API real
   shipped DNS-filter apps (AdGuard DNS, NextDNS, Cloudflare's own 1.1.1.1 app) use.
   Turning it on shows the person ONE system "Allow DNS Settings" prompt (not a
   Screen Time passcode) and from then on every DNS lookup this phone makes — every
   browser, every app, every search engine — goes through mtlogos.com/dns-query
   first. The actual block list never leaves the server; this just points the phone
   at the resolver that checks it. */
final class DnsFilter {
    /// 2026-10-12, real bug found in a security audit: this used to report whether the
    /// loadFromPreferences CALL ITSELF succeeded, not whether this app's DNS config is
    /// actually the one active on the device. If someone goes to iOS Settings -> General
    /// -> VPN & Device Management and turns off or deletes the Mt. Logos DNS config
    /// directly (a path Apple always exposes and this app has no way to block — see
    /// disable()'s own comment on that honest limit), the load call still succeeds fine
    /// with error == nil, so this kept reporting "protected" while every adult-content
    /// domain was resolving normally. NEDNSSettingsManager exposes a real isEnabled
    /// property for exactly this distinction; now actually reads it.
    static func isEnabled(completion: @escaping (Bool) -> Void) {
        NEDNSSettingsManager.shared().loadFromPreferences { error in
            // 2026-10-12, real bug found in a fresh audit pass: unlike enable()/disable()
            // just below, this completion was never dispatched to the main thread.
            // loadFromPreferences's callback queue isn't documented/guaranteed to be
            // main, and the only caller (WebView.swift's dnsFilter bridge) feeds this
            // straight into evaluateJavaScript(), which REQUIRES the main thread —
            // calling it off-thread is undefined behavior (most often a silent no-op).
            // renderBlockingSettings() calls this on nearly every Accountability-tab
            // render, so the "protected" indicator could nondeterministically fail to
            // update on a real, frequently-hit path, not just an edge case.
            let on = error == nil && NEDNSSettingsManager.shared().isEnabled
            DispatchQueue.main.async { completion(on) }
        }
    }

    /// Prompts the system "Allow DNS Settings" dialog and, once approved, routes the
    /// device's DNS through mtlogos.com/dns-query. DoH (DNS-over-HTTPS) — the same
    /// transport the server route already speaks — rather than DoT, since it's a plain
    /// HTTPS POST and needs no extra port/protocol allowances.
    static func enable(completion: @escaping (Bool, String?) -> Void) {
        let settings = NEDNSOverHTTPSSettings(servers: [])
        settings.serverURL = URL(string: "https://mtlogos.com/dns-query")
        let manager = NEDNSSettingsManager.shared()
        manager.dnsSettings = settings
        manager.saveToPreferences { error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                } else {
                    completion(true, nil)
                }
            }
        }
    }

    /// Reverses enable() — hands DNS back to whatever the device/network normally uses.
    /// Deliberately a real, working "turn it off" path: the accountability model here is
    /// the partner-approval flow around editing settings (see block_edit_* in
    /// worker/src/index.js), not technically preventing removal — same honest limit
    /// every phone-based blocker has, acknowledged directly to Kanyon already.
    /// Threads the real system error back (2026-10-11 fix) — this used to collapse any
    /// failure to a bare false, which is why the page could only ever show a generic
    /// "Something went wrong." with no way to tell what actually happened on the device.
    static func disable(completion: @escaping (Bool, String?) -> Void) {
        NEDNSSettingsManager.shared().removeFromPreferences { error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                } else {
                    completion(true, nil)
                }
            }
        }
    }
}
