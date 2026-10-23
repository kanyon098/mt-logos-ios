import SwiftUI
import WebKit
import AVFoundation
import UserNotifications

/* The whole app is one WKWebView pointed at mtlogos.com — see APP-STORE-CHECKLIST.md /
   the ship plan for why (subscriptions stay on the website, this is a free sign-in
   companion, no in-app purchase).

   isAppShell(req) on the Worker (worker/src/index.js) detects this wrapper by the
   " MtLogosApp/1" suffix on the User-Agent below and strips all pricing/subscribe UI
   from /login and /pay accordingly — that's what keeps this compliant with Apple
   Guideline 3.1.1 / 3.1.3(e). Don't drop that suffix without updating the Worker too. */
/// Safely embeds a Swift String as a single-quoted JS string literal inside an
/// evaluateJavaScript() call — used wherever a native error message (never trusted,
/// arbitrary text from the OS) gets handed to the page.
private func jsStringLiteral(_ s: String) -> String {
    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "'\(escaped)'"
}

final class WebViewStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var loadFailed = false

    let webView: WKWebView
    private let homeURL = URL(string: "https://mtlogos.com/?app=1")!

    // Everything on-domain stays inside the app; everything else (a mailto: link,
    // the YouTube walkthrough, an external share target) opens in Safari instead of
    // dead-ending in a WKWebView with no address bar or back button of its own.
    private let allowedHosts: Set<String> = [
        "mtlogos.com", "www.mtlogos.com", "skopoapp.com", "www.skopoapp.com"
    ]

    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 MtLogosApp/1"

    override init() {
        /* 2026-10-12, real bug Kanyon reported live: "the bar code scanner is not
           working. it did the whole screen as a camera and blacks out." Root cause:
           a bare WKWebViewConfiguration() defaults allowsInlineMediaPlayback to
           FALSE on iOS — meaning every <video> element, even one with the
           playsinline/muted HTML attributes the barcode scanner's camera feed
           already sets correctly (see mtλapp.html's #barcodeVideo), still gets
           forced into the native AVKit fullscreen video player the instant it
           starts playing. That's "did the whole screen as a camera." The native
           fullscreen player then can't properly render a raw live getUserMedia
           camera MediaStream the way it renders a normal video file — it's built
           for file/URL playback, not a live stream — which is the "blacks out"
           part: no actual crash, just nothing the player knows how to draw.
           Setting this true keeps every video (including this one) genuinely
           inline, exactly as its own HTML attributes already asked for.

           2026-10-12, STILL happening after the above fix, reported live: "it
           pulls up the camera window at first but then it expands the whole
           screen to camera view... if you x out of that live camera view, it
           will have read the code." allowsInlineMediaPlayback alone wasn't the
           whole story — it governs WHETHER inline playback is allowed, but
           WebKit separately gates WHETHER a given play() call is trusted enough
           to use it, based on mediaTypesRequiringUserActionForPlayback (default
           .all). The barcode scanner's play() happens inside an async
           getUserMedia().then() callback (decodeFromConstraints in mtλapp.html),
           not synchronously inside the tap that opened the scanner, so WebKit
           didn't credit it as a real user gesture and fell back to presenting
           the native fullscreen AVKit player for that specific play() call — a
           SEPARATE native view sitting on top of the DOM, which is exactly why
           closing the in-app modal (which does fire the instant a barcode
           decodes, same as always) didn't dismiss anything: there was a second,
           native-level fullscreen presentation still on screen needing its own
           manual dismissal. Setting this to [] (no media type ever requires a
           user-gesture-gated play) removes that trust gate entirely, so every
           play() call - sync or async - is honored inline. */
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        /* Breathe's Web Audio chimes have been reported silent on iOS three separate
           times (see mtλapp.html's brzAudioCtx()/brzUnlockAudio() comments — the
           gesture-unlock timing, the mid-session-suspend recovery, and the
           standalone-mode touchstart-vs-click gesture type have all been fixed on the
           JS side already, and it was STILL reported silent after each one). What
           none of those could reach: a WKWebView never activates an AVAudioSession on
           its own, and WITHOUT one iOS may route Web Audio output nowhere at all
           inside a wrapped app, regardless of anything the page's own script does —
           this is a plain gap on the native side, not something JS can fix.
           .playback, changed from .ambient 2026-10-07 after a fourth "still silent"
           report: .ambient is muted by the Ring/Silent switch, which is where most
           phones live, so the chimes were silenced by design. A breathing guide is
           followed eyes-closed and has to be heard, same reason meditation apps use
           .playback. .mixWithOthers keeps it from stopping someone's music or
           podcast. The page also asks for the same category itself
           (navigator.audioSession in brzAudioCtx()), so this and the JS agree.
           Failing silently on purpose (try?) — a session that can't activate should
           never crash the app over a sound effect. */
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.userAgent

        /* THE OTHER HALF of filling the screen. `.ignoresSafeArea()` in ContentView
           (see its comment) makes the web VIEW span the whole display — but the
           scroll view inside it still defaults to .automatic, which quietly adds
           content insets the size of the safe area. So the view was edge to edge
           while its CONTENT was pushed down from the top and up from the bottom,
           leaving strips of background exactly as if nothing had been fixed at all.
           Reported again 2026-09-16, after the .ignoresSafeArea() fix shipped.

           .never hands the whole surface to the page, which is what the web app
           already expects: it keeps its own bars and popups clear of the notch and
           home indicator with CSS env(safe-area-inset-*), and viewport-fit=cover is
           set precisely so those resolve to real values instead of zero. Two systems
           both reserving room for the same safe area is what produced the bands. */
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // Bridge for hapticTap() in mtλapp.html (Home/Settings/Skopo taps) — see
        // userContentController(_:didReceive:) below. Added to the SAME
        // WKWebViewConfiguration instance the webView above already owns; a
        // userContentController is a live, mutable object, so registering a handler
        // on it after the webView exists still reaches every page it loads.
        webView.configuration.userContentController.add(self, name: "haptic")
        // Bridge for requestApnsToken() in mtλapp.html (the Notifications toggle,
        // when running inside this wrapped build) — see userContentController(_:
        // didReceive:) below and Push.swift's AppDelegate, which is where the
        // actual token (or failure) gets handed back to the page.
        webView.configuration.userContentController.add(self, name: "apnsRegister")
        // Bridge for the content-blocking toggle in mtλapp.html (Accountability tab) —
        // see "dnsFilter" in userContentController(_:didReceive:) below and DnsFilter.swift.
        webView.configuration.userContentController.add(self, name: "dnsFilter")
        // Bridge for app-level blocking (App Store, future conditional app blocking) in
        // mtλapp.html — see "appBlocking" below and AppBlocking.swift. Separate feature
        // from dnsFilter above on purpose; see AppBlocking.swift's own long comment.
        webView.configuration.userContentController.add(self, name: "appBlocking")
        // Bridge for native Apple In-App Purchase (the /pay screen, app-shell mode) —
        // see "iap" below and IAPManager.swift.
        webView.configuration.userContentController.add(self, name: "iap")
        // A shield picked in an earlier session should still be in force on this one —
        // DnsFilter has no equivalent because NEDNSSettingsManager's setting already
        // persists itself at the OS level; ManagedSettingsStore does too, but applying it
        // again here is cheap and removes any doubt about it surviving a relaunch.
        AppBlocking.shared.reapplySavedShield()
        AppBlocking.shared.reapplyAppStoreBlock()

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
    }

    func load() {
        loadFailed = false
        webView.load(URLRequest(url: homeURL))
    }

    /* Universal Link entry point — see project.yml's associated-domains entitlement
       comment for the other half of this fix (the AASA/entitlement plumbing that gets
       iOS to hand a tapped mtlogos.com link to THIS app at all instead of Safari). Once
       iOS does hand it over, SwiftUI's .onOpenURL below calls this with the exact URL
       that was tapped — a referral link, an accountability pairing link, whatever path
       it was — and this just loads it straight into the same webView already on
       screen, same as any other in-app navigation. allowedHosts re-used rather than a
       second list, so this can never open a host the rest of the app wouldn't. */
    func openUniversalLink(_ url: URL) {
        guard allowedHosts.contains(url.host ?? "") else { return }
        webView.load(URLRequest(url: url))
    }

    @objc private func pullToRefresh() {
        webView.reload()
        webView.scrollView.refreshControl?.endRefreshing()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let host = url.host ?? ""
        let isOnDomain = allowedHosts.contains(host)
        // navigationAction.targetFrame == nil means a target="_blank" / window.open()
        // link with nowhere of its own to land — always send those out, even if the
        // host would otherwise be allowed, since there is no in-app tab to open it in.
        if navigationAction.targetFrame == nil || !isOnDomain {
            // "sms" added 2026-10-11 — acctTextCode() (Accountability tab's "Text it"
            // button, mtλapp.html) navigates to sms:?&body=... to hand off a pairing
            // code via Messages; missing from this list meant the navigation was just
            // silently cancelled inside the WKWebView, the exact "button does nothing"
            // report, with no error and nothing to see on screen.
            if ["http", "https", "mailto", "tel", "sms"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // Belt-and-suspenders for window.open() calls WKWebView routes here instead of
    // through decidePolicyFor above, depending on how the page called it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { loadFailed = true }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { loadFailed = true }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadFailed = false
    }

    // MARK: - WKScriptMessageHandler: haptics

    // hapticTap() in mtλapp.html posts here on tapping Home, Settings, or Skopo — a
    // light tap-buzz. navigator.vibrate() (the JS side's other attempt) does nothing
    // on iOS; WebKit has never implemented the Vibration API there, on-device or in
    // this wrapper, so this bridge is the only way to actually feel it on iPhone.
    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        if message.name == "haptic" {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        if message.name == "apnsRegister" {
            // Must happen on the main thread, and the actual system permission
            // prompt only appears once per install — a second tap after already
            // granting (or denying) just re-registers silently, matching how the
            // browser side's Notification.requestPermission() behaves too.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    if granted {
                        UIApplication.shared.registerForRemoteNotifications()
                    } else {
                        AppDelegate.shared?.webView?.evaluateJavaScript("window.__apnsTokenFailed && window.__apnsTokenFailed()")
                    }
                }
            }
            return
        }
        if message.name == "dnsFilter" {
            // body is one of "enable" | "disable" | "status" — see dnsFilterEnable()/
            // dnsFilterStatus() in mtλapp.html, which is what's waiting on the
            // matching window.__dnsFilter* callback this posts back.
            let command = (message.body as? String) ?? "status"
            switch command {
            case "enable":
                DnsFilter.enable { ok, errorMessage in
                    let arg = ok ? "true" : "false, " + jsStringLiteral(errorMessage ?? "Could not turn it on.")
                    AppDelegate.shared?.webView?.evaluateJavaScript("window.__dnsFilterResult && window.__dnsFilterResult(\(arg))")
                }
            case "disable":
                DnsFilter.disable { ok, errorMessage in
                    let arg = ok ? "true" : "false, " + jsStringLiteral(errorMessage ?? "Could not turn it off.")
                    AppDelegate.shared?.webView?.evaluateJavaScript("window.__dnsFilterResult && window.__dnsFilterResult(\(arg))")
                }
            default:
                DnsFilter.isEnabled { on in
                    AppDelegate.shared?.webView?.evaluateJavaScript("window.__dnsFilterStatus && window.__dnsFilterStatus(\(on ? "true" : "false"))")
                }
            }
            return
        }
        if message.name == "appBlocking" {
            // body is one of "pickApps" | "editRules" | "clear" | "status" — see
            // appBlockingCall() in mtλapp.html, waiting on window.__appBlockingResult.
            // pickApps and editRules are both gated behind the SAME accountability-
            // partner approval the web page already checks before ever posting either
            // command here (renderAppBlockingSettings()) — not re-checked natively,
            // same honesty-not-lock-out model as DnsFilter.disable() and the DNS toggle
            // itself: the gate lives in the UI the person sees, not a tamper-proof wall.
            let command = (message.body as? String) ?? "status"
            switch command {
            case "pickApps":
                guard let vc = topViewController() else {
                    AppDelegate.shared?.webView?.evaluateJavaScript("window.__appBlockingResult && window.__appBlockingResult(false, 0, \(jsStringLiteral("Could not show the picker.")))")
                    return
                }
                AppBlocking.shared.presentPicker(from: vc) { ok, count, errorMessage in
                    let errArg = errorMessage == nil ? "null" : jsStringLiteral(errorMessage!)
                    AppDelegate.shared?.webView?.evaluateJavaScript("window.__appBlockingResult && window.__appBlockingResult(\(ok ? "true" : "false"), \(count), \(errArg))")
                }
            case "editRules":
                guard let vc = topViewController() else {
                    AppDelegate.shared?.webView?.evaluateJavaScript("window.__appBlockingResult && window.__appBlockingResult(false, 0, \(jsStringLiteral("Could not show the rule editor.")))")
                    return
                }
                AppBlocking.shared.presentRuleEditor(from: vc) { ok in
                    AppDelegate.shared?.webView?.evaluateJavaScript("window.__appBlockingResult && window.__appBlockingResult(\(ok ? "true" : "false"), 0, null)")
                }
            case "clear":
                AppBlocking.shared.clear { ok in
                    AppDelegate.shared?.webView?.evaluateJavaScript("window.__appBlockingResult && window.__appBlockingResult(\(ok ? "true" : "false"), 0, null)")
                }
            // One-tap App Store block (2026-10-11) — a separate, simpler mechanism from
            // the picker-based commands above, see AppBlocking.swift's
            // setAppStoreBlocked()/isAppStoreBlocked() for why this doesn't need a picker.
            case "toggleAppStore":
                let wantsOn = !AppBlocking.shared.isAppStoreBlocked()
                // 2026-10-12: setAppStoreBlocked is now async (requests Screen Time
                // authorization first — see its own comment) and reports back whether it
                // actually took effect, so the web UI can never show "blocked" when
                // authorization was denied and nothing was really enforced.
                AppBlocking.shared.setAppStoreBlocked(wantsOn) { ok in
                    let reportedState = ok ? wantsOn : AppBlocking.shared.isAppStoreBlocked()
                    AppDelegate.shared?.webView?.evaluateJavaScript("window.__appStoreBlockStatus && window.__appStoreBlockStatus(\(reportedState ? "true" : "false"))")
                }
            case "appStoreStatus":
                AppDelegate.shared?.webView?.evaluateJavaScript("window.__appStoreBlockStatus && window.__appStoreBlockStatus(\(AppBlocking.shared.isAppStoreBlocked() ? "true" : "false"))")
            // Clock-tamper flag (2026-10-11) — see ClockIntegrityGuard. "clearTamper" is
            // how the person acknowledges they saw the note, same one-way ack pattern as
            // any other dismissible warning; it does NOT undo whatever triggered it.
            // 2026-10-12: now reports through its OWN __appTamperStatus callback instead
            // of sharing __appStoreBlockStatus with toggleAppStore/appStoreStatus above —
            // see mtλapp.html's appTamperCall() for the real race this was causing
            // (toggleAppStore can take an arbitrarily long, human-timescale time waiting
            // on the system Screen Time permission dialog; a tamper call landing on the
            // same shared resolve slot during that window could steal/corrupt both
            // answers).
            case "tamperStatus":
                AppDelegate.shared?.webView?.evaluateJavaScript("window.__appTamperStatus && window.__appTamperStatus(\(AppBlocking.shared.clockTamperDetected() ? "true" : "false"))")
            case "clearTamper":
                AppBlocking.shared.clearClockTamperFlag()
                AppDelegate.shared?.webView?.evaluateJavaScript("window.__appTamperStatus && window.__appTamperStatus(false)")
            default:
                let (isActive, count) = AppBlocking.shared.status()
                AppDelegate.shared?.webView?.evaluateJavaScript("window.__appBlockingStatus && window.__appBlockingStatus(\(isActive ? "true" : "false"), \(count))")
            }
            return
        }
        if message.name == "iap" {
            // body is {command:"products"|"buy"|"restore", productId?:"..."} — see
            // IAPManager.swift for the actual purchase flow; this just bridges it to
            // the /pay screen's JS (mtλapp.html, app-shell mode). All three
            // IAPManager calls are async, so each branch runs its own Task rather
            // than blocking this synchronous delegate callback.
            let body = message.body as? [String: Any]
            let command = (body?["command"] as? String) ?? "products"
            switch command {
            case "products":
                // @MainActor on the Task itself, not just the IAPManager calls inside it —
                // a plain `Task { }` here does NOT inherit the main thread just because
                // userContentController(_:didReceive:) was called on it; it runs on the
                // global concurrent executor, and execution resumes there (not back on
                // main) after each `await` returns. Every evaluateJavaScript call below
                // was therefore firing on a background thread — WKWebView is main-thread-
                // only, and driving it off-main can corrupt its internal state silently
                // rather than crashing outright. Real report, 2026-10-22, the day this
                // shipped: "the buttons keep freezing and i have to close the app and
                // reopen" — exactly the shape of a corrupted shared WKWebView, since this
                // app is ONE webview for every tab (see this file's own top comment), so a
                // single bad hop here on the /pay screen could freeze everything, not just
                // the purchase buttons. NOT DEVICE-VERIFIED that this was really the cause
                // (no local Mac to reproduce the freeze against) — it is the most concrete,
                // mechanically sound explanation available given the exact timing, and the
                // fix is strictly more correct regardless of whether it turns out to be the
                // whole story.
                Task { @MainActor in
                    await IAPManager.shared.loadProducts()
                    let products = await IAPManager.shared.products
                    let items = products.map { p in
                        "{\"id\":\(jsStringLiteral(p.id)),\"displayName\":\(jsStringLiteral(p.displayName)),\"displayPrice\":\(jsStringLiteral(p.displayPrice))}"
                    }
                    let json = "[" + items.joined(separator: ",") + "]"
                    _ = try? await AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapProducts && window.__iapProducts(\(json))")
                }
            case "buy":
                guard let productId = body?["productId"] as? String else {
                    // NOT inside the Task below, so this one correctly resolves to the
                    // old completion-handler evaluateJavaScript overload (same as every
                    // other non-async call site above) — see the Task-only fix below.
                    AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapPurchaseResult && window.__iapPurchaseResult(false, \(jsStringLiteral("Missing product.")))")
                    return
                }
                Task { @MainActor in
                    await IAPManager.shared.loadProducts()
                    let products = await IAPManager.shared.products
                    guard let product = products.first(where: { $0.id == productId }) else {
                        _ = try? await AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapPurchaseResult && window.__iapPurchaseResult(false, \(jsStringLiteral("That item isn’t available right now.")))")
                        return
                    }
                    let result = await IAPManager.shared.purchase(product)
                    switch result {
                    case .success(let originalTransactionId):
                        _ = try? await AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapPurchaseResult && window.__iapPurchaseResult(true, null, \(jsStringLiteral(originalTransactionId)), \(jsStringLiteral(productId)))")
                    case .failure(.cancelled):
                        // A cancel isn't an error worth a message — the web UI just
                        // goes back to whatever it showed before the purchase sheet.
                        _ = try? await AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapPurchaseResult && window.__iapPurchaseResult(false, null)")
                    case .failure(.noAccountToken):
                        _ = try? await AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapPurchaseResult && window.__iapPurchaseResult(false, \(jsStringLiteral("Could not reach your account — check your connection and try again.")))")
                    case .failure(.pending):
                        _ = try? await AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapPurchaseResult && window.__iapPurchaseResult(false, \(jsStringLiteral("This purchase needs approval (Ask to Buy) — it’ll finish once that’s approved.")))")
                    case .failure(.storeKit(let error)):
                        _ = try? await AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapPurchaseResult && window.__iapPurchaseResult(false, \(jsStringLiteral(error.localizedDescription)))")
                    case .failure(.unknown):
                        _ = try? await AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapPurchaseResult && window.__iapPurchaseResult(false, \(jsStringLiteral("Something went wrong.")))")
                    }
                }
            case "restore":
                Task { @MainActor in
                    let found = await IAPManager.shared.restorePurchases()
                    if let found {
                        _ = try? await AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapRestoreResult && window.__iapRestoreResult(true, \(jsStringLiteral(found.originalTransactionId)), \(jsStringLiteral(found.productId)))")
                    } else {
                        _ = try? await AppDelegate.shared?.webView?.evaluateJavaScript("window.__iapRestoreResult && window.__iapRestoreResult(false, null, null)")
                    }
                }
            default:
                break
            }
            return
        }
    }

    // MARK: - WKUIDelegate: JS alert/confirm/prompt

    // Conforming to WKUIDelegate and setting webView.uiDelegate above is NOT enough on
    // its own — these three panel methods are each individually optional, and WKWebView
    // silently no-ops (alert: nothing shown, just completes; confirm/prompt: completes
    // as cancelled/nil) for any of them that isn't actually implemented. That is exactly
    // what made every window.confirm()/alert()/prompt() in the web app do nothing at all
    // inside this wrapper — reported 2026-09-12 as "the Gym Log delete button does
    // nothing" (confirm()), and the web app's own appConfirm()/appConfirmAsync() JS-side
    // workaround (mtλapp.html) exists because of this exact gap. Implementing the real
    // panels here fixes it at the source — for every confirm()/alert()/prompt() call
    // site, present and future, not just the ones patched on the JS side.
    private func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let vc = topViewController() else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        vc.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let vc = topViewController() else { completionHandler(false); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        vc.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let vc = topViewController() else { completionHandler(nil); return }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        vc.present(alert, animated: true)
    }
}

private struct WebViewRepresentable: UIViewRepresentable {
    @ObservedObject var store: WebViewStore
    func makeUIView(context: Context) -> WKWebView { store.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var store = WebViewStore()

    // Matches manifest.webmanifest's background_color (#04050d) so the launch
    // moment and any offline screen never flash a mismatched color.
    private let brandBackground = Color(red: 4.0 / 255, green: 5.0 / 255, blue: 13.0 / 255)

    var body: some View {
        ZStack {
            brandBackground.ignoresSafeArea()
            // Reported 2026-09-12: "doesn't fill the screen... looks cheap." Without
            // .ignoresSafeArea() here, SwiftUI constrains the WKWebView itself to the
            // safe area, leaving a strip of brandBackground showing at the top/bottom
            // instead of real page content — even though the web app (mtλapp.html) is
            // already built to handle this ITSELF via CSS env(safe-area-inset-*) on
            // every full-screen surface and popup (see .home-screen, .overlay, etc. —
            // viewport-fit=cover is set precisely so those resolve to real values). The
            // web page already keeps its own popups/buttons clear of the status bar and
            // home indicator; the native side just needs to get out of the way and let
            // the page extend edge to edge like it was designed to.
            WebViewRepresentable(store: store)
                .ignoresSafeArea()
                .opacity(store.loadFailed ? 0 : 1)
            if store.loadFailed {
                OfflineView(retry: store.load)
            }
        }
        .onAppear {
            // AppDelegate needs this to hand a device token (or a failure) back
            // to the page once didRegisterForRemoteNotificationsWithDeviceToken
            // fires — see Push.swift. Cheap to set on every appear; it's just a
            // weak reference, never re-creates anything.
            AppDelegate.shared?.webView = store.webView
            if store.webView.url == nil { store.load() }
        }
        // Universal Links land here — see WebViewStore.openUniversalLink's own comment
        // and project.yml's associated-domains entitlement for the full picture.
        .onOpenURL { url in store.openUniversalLink(url) }
        /* 2026-10-20, Kanyon, real bug: "when i open up the app it'll make me click it
           once and then click it twice... the first tap nonfunctional." A background
           Explore agent traced this to a well-documented WebKit behavior: a WKWebView's
           document starts with no window focus, and the page's own focus event only
           fires after the FIRST touch — so that first tap gets consumed re-establishing
           focus/responder state instead of reaching the page as a real click, and the
           second tap on the same element then works normally. didBecomeActiveNotification
           fires both right after a cold launch finishes AND every time the app returns
           from the background/app-switcher — the two moments this was actually reported
           for. Forcing the webview to resign and re-become first responder there is the
           standard native-side nudge for this WebKit quirk: it re-runs that focus
           handshake itself, ahead of the user's first real tap, instead of letting that
           tap be the thing that triggers it. Low-risk either way — resign/become
           firstResponder on a WKWebView doesn't touch page state or JS — but this is a
           best-effort mitigation for an underlying WebKit bug, not a confirmed root-cause
           fix; verify on a real device (open the app, tap immediately) before assuming
           it's fully gone. */
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                store.webView.resignFirstResponder()
                store.webView.becomeFirstResponder()
            }
        }
    }
}

private struct OfflineView: View {
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.7))
            Text("Can't reach Mt. Logos")
                .font(.headline)
                .foregroundColor(.white)
            Text("Check your connection and try again.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
            Button(action: retry) {
                Text("Retry")
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .foregroundColor(.black)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .padding()
    }
}
