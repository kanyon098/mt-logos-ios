import UIKit
import WebKit
import UserNotifications

/* Native push registration for the wrapped App Store app — see the "APNs"
   module in worker/src/index.js for why this exists at all: a plain
   WKWebView has never implemented the Web Push API, so push_subscriptions
   (Web Push) can never reach this build regardless of anything the page's
   own JS does. This is the real-APNs half, requested by Kanyon after
   noticing no notifications were ever showing up in the App Store build's
   Notification Center.

   SwiftUI's App protocol has no direct hook for
   application(_:didRegisterForRemoteNotificationsWithDeviceToken:) — that's
   a plain UIApplicationDelegate callback, so this class exists purely to
   receive it (via @UIApplicationDelegateAdaptor in MtLogosApp.swift) and
   hand the result back to the one thing that actually needs it: the web
   page's own JS. `webView` is set by ContentView's onAppear (WebView.swift)
   once the WebViewStore that owns it exists — this class is created before
   that, so it can't just reach in and grab it up front. */
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate?
    weak var webView: WKWebView?

    func application(_ application: UIApplication,
                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        AppDelegate.shared = self
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // requestApnsToken() in mtλapp.html is waiting on exactly one of these two
    // JS calls landing — see its 10-second timeout for what happens if neither
    // ever does (a broken/slow round trip, not just an outright permission
    // denial, which is handled before registerForRemoteNotifications() is even
    // called — see WebView.swift's "apnsRegister" message handler).
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        webView?.evaluateJavaScript("window.__apnsTokenReceived && window.__apnsTokenReceived('\(hex)')")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        webView?.evaluateJavaScript("window.__apnsTokenFailed && window.__apnsTokenFailed()")
    }

    // Without this, a push that arrives while the app is already open (e.g.
    // testing an accountability poke with the app in the foreground) is
    // received but never actually shown — WKWebView has no concept of "handle
    // this the way Safari would," so it has to be told explicitly to still
    // present the banner/sound rather than swallowing it silently.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
