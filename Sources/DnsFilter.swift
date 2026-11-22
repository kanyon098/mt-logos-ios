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
    ///
    /// `token` (2026-11-09) — this account's own dns_tokens value, fetched by the web
    /// page (GET /api/dns-token) and passed down through WebView.swift's "dnsFilter"
    /// bridge. Baked right into the resolver URL itself, exactly the way a real
    /// DNS-filter app would scope a shared resolver to one subscriber — it's what lets
    /// /dns-query tell this phone's queries apart from everyone else's, so a person's
    /// own added sites (see user_block_domains in worker/src/index.js) only ever block
    /// for THEM, never globally. Optional and backward compatible on purpose: nil just
    /// means "global list only," the exact behavior this had before the per-user list
    /// existed, so a failed token fetch never blocks turning protection on at all.
    /// 2026-11-22, REAL BUG, reported live: "Block adult content" showed a real
    /// system error, "configuration is unchanged," and refused to turn on.
    /// Root cause: this called saveToPreferences on a `NEDNSSettingsManager`
    /// that had never loaded the device's current preferences first. This is
    /// a well-known NEDNSSettingsManager gotcha, not specific to this app —
    /// the manager has no baseline to diff the new settings against until
    /// loadFromPreferences has run at least once, so a save can be refused as
    /// a no-op ("unchanged") even when nothing was ever actually turned on.
    /// Fix: always loadFromPreferences first, build and assign the new
    /// settings inside that completion, then save — same pattern
    /// isEnabled() above already uses correctly.
    static func enable(token: String?, completion: @escaping (Bool, String?) -> Void) {
        let manager = NEDNSSettingsManager.shared()
        manager.loadFromPreferences { _ in
            let settings = NEDNSOverHTTPSSettings(servers: [])
            let base = "https://mtlogos.com/dns-query"
            let urlString: String
            if let token, !token.isEmpty {
                urlString = base + "/" + token
            } else {
                urlString = base
            }
            settings.serverURL = URL(string: urlString)
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
        // Same loadFromPreferences-first discipline as enable() above, applied
        // here too even though removeFromPreferences hasn't been reported
        // broken — it's the correct way to use this manager either direction,
        // and there's no reason to leave the same class of bug half-fixed.
        let manager = NEDNSSettingsManager.shared()
        manager.loadFromPreferences { _ in
            manager.removeFromPreferences { error in
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
}
