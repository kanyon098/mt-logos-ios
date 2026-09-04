import SwiftUI
import WebKit

/* The whole app is one WKWebView pointed at mtlogos.com — see APP-STORE-CHECKLIST.md /
   the ship plan for why (subscriptions stay on the website, this is a free sign-in
   companion, no in-app purchase).

   isAppShell(req) on the Worker (worker/src/index.js) detects this wrapper by the
   " MtLogosApp/1" suffix on the User-Agent below and strips all pricing/subscribe UI
   from /login and /pay accordingly — that's what keeps this compliant with Apple
   Guideline 3.1.1 / 3.1.3(e). Don't drop that suffix without updating the Worker too. */
final class WebViewStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
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
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.userAgent

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
            WebViewRepresentable(store: store)
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
