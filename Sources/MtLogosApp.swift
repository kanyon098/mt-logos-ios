import SwiftUI

@main
struct MtLogosApp: App {
    // AppDelegate (Push.swift) exists purely to receive
    // didRegisterForRemoteNotificationsWithDeviceToken — a plain
    // UIApplicationDelegate callback SwiftUI's App protocol has no direct hook
    // for. @UIApplicationDelegateAdaptor is the supported bridge between them.
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
