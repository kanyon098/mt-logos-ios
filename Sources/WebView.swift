import SwiftUI
import WebKit
import AVFoundation

/* The whole app is one WKWebView pointed at mtlogos.com — see APP-STORE-CHECKLIST.md /
   the ship plan for why (subscriptions stay on the website, this is a free sign-in
   companion, no in-app purchase).

   isAppShell(req) on the Worker (worker/src/index.js) detects this wrapper by the
   " MtLogosApp/1" suffix on the User-Agent below and strips all pricing/subscribe UI
   from /login and /pay accordingly — that's what keeps this compliant with Apple
   Guideline 3.1.1 / 3.1.3(e). Don't drop that suffix without updating the Worker too. */
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
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
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
           .ambient is deliberate, not .playback: it activates real audio output while
           still respecting the physical Silent switch (mixes with other audio, gets
           interrupted by system sounds) — matching how a UI chime should behave, and
           consistent with the "still can't do anything about the silent switch, and
           shouldn't" reasoning already documented on the JS side. Failing silently on
           purpose (try?) — a session that can't activate should never crash the app
           over a sound effect. */
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
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

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
    }

    func load() {
        loadFailed = false
        webView.load(URLRequest(url: homeURL))
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
            if ["http", "https", "mailto", "tel"].contains(url.scheme ?? "") {
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
        guard message.name == "haptic" else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            if store.webView.url == nil { store.load() }
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
