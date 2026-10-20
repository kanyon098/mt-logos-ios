import Foundation
import StoreKit
import WebKit

/* Apple In-App Purchase — native base-plan subscriptions + Skopo's one-time unlock.
   See worker/src/index.js's big "Apple In-App Purchase (StoreKit..." comment for the
   full server-side design and trust model; this is the client half. Stripe and the
   website stay completely untouched — this only ever runs inside the wrapped app,
   and it never grants anything itself: a purchase here just starts the StoreKit
   flow and finishes the local transaction. The actual paid_until/skopo_unlocked_at
   grant happens server-side, once Apple's own servers process the purchase and
   notify the webhook, which re-verifies directly with Apple rather than trusting
   anything this client reports. See WebView.swift's "iap" message handler for the
   JS bridge that lets the web page (the /pay screen) actually call this.

   Product IDs are fixed constants, not server config — App Store Connect's Product
   ID field is set ONCE at creation and can never change afterward, so there is no
   "configure it later" step the way IOS_APP_ID etc. have. These three strings ARE
   the configuration: type them into App Store Connect EXACTLY as they appear here.
   wrangler.toml keeps its own copy of the same three ids (APPLE_IAP_PRODUCT_ID_*)
   for the server side to key its webhook routing on — kept in sync by hand, since
   the server has no way to import a Swift file. */
enum MtLogosProduct {
    static let monthly = "com.mtlogos.app.monthly"
    static let annual = "com.mtlogos.app.annual"
    static let skopo = "com.mtlogos.app.skopo"
    static let all: Set<String> = [monthly, annual, skopo]
}

enum IAPError: Error {
    case noAccountToken   // couldn't reach /api/apple/account-token — not logged in, offline, or the server hiccuped
    case cancelled
    case pending          // Ask to Buy, or similar — StoreKit itself hasn't resolved this purchase yet
    case unknown
    case storeKit(Error)
}

@MainActor
final class IAPManager: NSObject, ObservableObject {
    static let shared = IAPManager()

    @Published var products: [Product] = []
    @Published var purchaseInFlight = false

    private var updatesTask: Task<Void, Never>?

    private override init() {
        super.init()
        /* StoreKit can hand a transaction to this app OUTSIDE a direct purchase()
           call entirely — an Ask to Buy approval that lands later, a renewal that
           happened while the app wasn't running, a purchase made on another device
           that's now syncing in. Transaction.updates is the one feed that catches
           every one of those, not just purchases this session itself started —
           without it, those would just sit unfinished until the next time
           loadProducts()/purchase() happened to run. */
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                await self?.finishLocally(update)
            }
        }
    }

    deinit { updatesTask?.cancel() }

    func loadProducts() async {
        do {
            products = try await Product.products(for: MtLogosProduct.all)
        } catch {
            products = []
        }
    }

    /// Starts a purchase for one product. Fetches a fresh account-token from the
    /// server FIRST (see fetchAccountToken()'s own comment) and attaches it as
    /// appAccountToken — the ONLY way the webhook can later map this purchase back
    /// to the right Mt. Logos account, since App Store purchases don't reliably
    /// carry an email. A purchase that can't get a token is refused outright
    /// rather than letting someone pay for something that could never actually
    /// get linked back to their account.
    ///
    /// On success, returns the transaction's originalTransactionID — NOT itself a
    /// grant of anything (see finishLocally's comment: this client's own report is
    /// never trusted), but handed back to the web page so it can call
    /// /api/apple/confirm and get an immediate answer instead of waiting on
    /// Apple's server notification, which can take anywhere from seconds to a few
    /// minutes to arrive. Same "beat the webhook" shape the Stripe flow already
    /// uses for its own ?paid=1/?skopo_unlocked=1 return-trip handlers.
    func purchase(_ product: Product) async -> Result<String, IAPError> {
        guard let token = await fetchAccountToken() else { return .failure(.noAccountToken) }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase(options: [.appAccountToken(token)])
            switch result {
            case .success(let verification):
                let originalId = await finishLocally(verification)
                guard let originalId else { return .failure(.unknown) }   // verification failed StoreKit's own check
                return .success(originalId)
            case .userCancelled:
                return .failure(.cancelled)
            case .pending:
                return .failure(.pending)
            @unknown default:
                return .failure(.unknown)
            }
        } catch {
            return .failure(.storeKit(error))
        }
    }

    /// "Restore purchases" — re-syncs StoreKit's local transaction list from
    /// Apple (a reinstall, or a purchase made on another device signed into the
    /// same Apple ID), then looks at what's CURRENTLY entitled on this Apple ID
    /// for our three known products. Returns the same (originalTransactionId,
    /// productId) shape purchase() does, for the EXACT same reason: a restored
    /// transaction already carries whatever appAccountToken it was purchased
    /// with, so running it through the same /api/apple/confirm round-trip (see
    /// the "iap" bridge in WebView.swift) is what actually reconnects it to this
    /// account server-side — AppStore.sync() alone only affects this device's
    /// local StoreKit state, it never calls back to the Worker on its own.
    /// Prefers an active base-plan subscription over Skopo if somehow both are
    /// current, since the base plan is what actually gates the whole app.
    func restorePurchases() async -> (originalTransactionId: String, productId: String)? {
        try? await AppStore.sync()
        var skopoFound: (String, String)? = nil
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            guard MtLogosProduct.all.contains(transaction.productID) else { continue }
            let found = (String(transaction.originalID), transaction.productID)
            if transaction.productID == MtLogosProduct.skopo { skopoFound = found } else { return found }
        }
        return skopoFound
    }

    /// StoreKit's OWN on-device signature check (Apple's framework verifying its
    /// own receipt) — unrelated to, and not a substitute for, the server-side
    /// trust model described in index.js: the server never trusts what THIS
    /// client reports either, it always re-asks Apple directly once the webhook
    /// fires or /api/apple/confirm is called. This just filters out a tampered
    /// local transaction before bothering to finish() it, and calls finish() so
    /// it stops reappearing in Transaction.updates forever — no direct "I bought
    /// it" call to the Worker here, on purpose. Returns the transaction's
    /// originalID (as a string) on a verified transaction, so purchase() above
    /// can hand it to the web page; the Transaction.updates listener in init()
    /// just discards it, since a background-delivered update has no in-flight
    /// JS call waiting on an answer.
    @discardableResult
    private func finishLocally(_ verification: VerificationResult<Transaction>) async -> String? {
        guard case .verified(let transaction) = verification else { return nil }
        let originalId = String(transaction.originalID)
        await transaction.finish()
        return originalId
    }

    /// URLSession and WKWebView keep SEPARATE cookie jars on iOS by default — the
    /// webview's session cookie (`sid`, HttpOnly — set server-side by
    /// sessionCookie() in worker/src/index.js) never reaches a plain
    /// URLSession.shared request on its own. Pulled from WKWebView's own cookie
    /// store and attached by hand; this is the one place this app's native code
    /// makes an AUTHENTICATED call back to the Worker, so nothing existing already
    /// solved this problem.
    private func fetchAccountToken() async -> UUID? {
        guard let url = URL(string: "https://mtlogos.com/api/apple/account-token") else { return nil }
        let cookies = await allWebViewCookies()
        guard let sid = cookies.first(where: { $0.name == "sid" && $0.domain.contains("mtlogos.com") }) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("\(sid.name)=\(sid.value)", forHTTPHeaderField: "Cookie")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(AccountTokenResponse.self, from: data)
            return UUID(uuidString: decoded.token)
        } catch {
            return nil
        }
    }

    private func allWebViewCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private struct AccountTokenResponse: Decodable { let token: String }
}
