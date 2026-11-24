import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// TTMailer SDK: registers the device and its push token, signs the user up to the newsletter (with a confirmation
/// e-mail) and reports opened pushes. Call `configure(appKey:)` once at launch; everything else may be called from any
/// thread. Calls that only update the installation never throw: the SDK keeps the state and sends it when it can.
public enum TTMailer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var engine: Engine?
    nonisolated(unsafe) private static var observer: NSObjectProtocol?
    nonisolated(unsafe) private static var automaticPurchases = false
    nonisolated(unsafe) private static var lifetimeProducts: Set<String>?
    nonisolated(unsafe) private static var storeObserver: Task<Void, Never>?

    static var current: Engine? { lock.lock(); defer { lock.unlock() }; return engine }

    /// Starts the SDK with the app key from TTMailer (Nastavení → Aplikace (SDK)).
    /// - Parameters:
    ///   - appKey: `tta_…`, the app's public key.
    ///   - baseURL: the TTMailer server.
    ///   - linkKey: the push data key that holds the push's link (the project's push format, `redirectUrl` by default).
    public static func configure(appKey: String, baseURL: URL = URL(string: "https://mailer.tappytaps.com")!, linkKey: String = "redirectUrl") {
        configure(Engine(appKey: appKey, baseURL: baseURL, linkKey: linkKey,
                         transport: URLSessionTransport(session: .shared), store: UserDefaultsStore(),
                         deviceInfo: { DeviceInfo.current() }))
    }

    static func configure(_ e: Engine) {
        lock.lock()
        engine = e
        lock.unlock()
        Task { _ = await e.sync(); await e.flushOpens(); await e.flushChanges() }
        #if canImport(UIKit) && !os(watchOS)
        DispatchQueue.main.async {
            if let o = observer { NotificationCenter.default.removeObserver(o) }
            observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
                guard let e = current else { return }
                Task { _ = await e.sync(); await e.flushOpens(); await e.flushChanges(); await readStore() }
            }
        }
        #endif
    }

    /// The id of this installation in TTMailer (changes after `reset()` or `deleteContact()`).
    public static func installationId() async -> String? { await current?.installationId }

    /// The APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public static func setPushToken(_ deviceToken: Data) {
        guard let e = current else { return }
        Task { await e.setPushToken(deviceToken) }
    }

    /// A push token as text (e.g. an FCM token when the app uses Firebase Messaging on iOS).
    public static func setPushToken(_ token: String) {
        guard let e = current else { return }
        Task { await e.setPushToken(token) }
    }

    /// Whether the user wants notifications (the app's own switch, or the system permission).
    public static func setPushEnabled(_ enabled: Bool) {
        guard let e = current else { return }
        Task { await e.setPushEnabled(enabled) }
    }

    /// The app's own account id when the user signs in, `nil` when they sign out. Use an unguessable id (an account
    /// UUID): it joins this installation with the user's other devices.
    public static func setUserId(_ userId: String?) {
        guard let e = current else { return }
        Task { await e.setUserId(userId) }
    }

    /// Whether TTMailer learns when the user last used the app (on by default): the SDK reports it at launch and when the
    /// app becomes active, at most once a day, for audiences like "used the app in the last 30 days". Off: the
    /// installation is still sent when it changes, but never counts as activity. Kept between launches.
    public static func setActivityTracking(_ enabled: Bool) {
        guard let e = current else { return }
        Task { await e.setActivityTracking(enabled) }
    }

    /// The language the user chose in the app, when it differs from the system's (e.g. "de" or "pt-BR"); `nil` goes
    /// back to the system language. TTMailer writes to the user in it. Kept between launches.
    public static func setLanguage(_ language: String?) {
        guard let e = current else { return }
        Task { await e.setLanguage(language) }
    }

    /// Adds tags to the user's contact in TTMailer (for audiences), e.g. `["sportovec"]`. Keys: a-z, 0-9, _ and -, 40
    /// at most (uppercase is lowered). Kept and sent when the device is online.
    public static func addTags(_ tags: [String]) {
        guard let e = current else { return }
        Task { await e.addTags(tags) }
    }

    /// Removes tags from the user's contact in TTMailer.
    public static func removeTags(_ tags: [String]) {
        guard let e = current else { return }
        Task { await e.removeTags(tags) }
    }

    /// The user's premium as the app knows it (e.g. from RevenueCat): until when, its kind (`paid`, `trial`, `offer`…)
    /// and when it started. A date in the past says it ended. Sent once, again only when it changes.
    public static func setPremium(until: Date, kind: String? = nil, startedAt: Date? = nil) {
        guard let e = current else { return }
        Task { await e.setPremium(PremiumReport(until: until, lifetime: false, kind: kind, startedAt: startedAt, products: nil)) }
    }

    /// A lifetime premium (a one-time purchase that unlocks the app for good).
    public static func setLifetimePremium(kind: String = "lifetime", startedAt: Date? = nil) {
        guard let e = current else { return }
        Task { await e.setPremium(PremiumReport(until: nil, lifetime: true, kind: kind, startedAt: startedAt, products: nil)) }
    }

    /// Turns on the automatic premium (off by default): the SDK reads the user's purchases from StoreKit 2 at launch,
    /// when the app becomes active and on every new transaction, and tells TTMailer the subscription's end and kind
    /// (`trial` / `paid`) and the one-time products owned (tags `koupeno_<product>`). Every non-consumable makes a
    /// lifetime premium; an app that also sells add-ons (e.g. a theme pack) names the ones that unlock the app in
    /// `lifetimeProductIds`, the others are only tags. Call it after `configure` on every launch. Use it or
    /// `setPremium`, not both.
    public static func enableAutomaticPurchases(lifetimeProductIds: Set<String>? = nil) {
        #if canImport(StoreKit)
        guard #available(iOS 15.0, macOS 12.0, *) else { return }
        lock.lock()
        automaticPurchases = true
        lifetimeProducts = lifetimeProductIds
        storeObserver?.cancel()
        storeObserver = StoreReader.observe { await readStore() }
        lock.unlock()
        Task { await readStore() }
        #endif
    }

    static func readStore() async {
        #if canImport(StoreKit)
        guard #available(iOS 15.0, macOS 12.0, *) else { return }
        let (e, on, products): (Engine?, Bool, Set<String>?) = { lock.lock(); defer { lock.unlock() }; return (engine, automaticPurchases, lifetimeProducts) }()
        guard let e, on else { return }
        await e.storeEntitlements(await StoreReader.entitlements(), lifetimeProducts: products)
        #endif
    }

    /// Signs the address up to the newsletter. TTMailer sends a confirmation e-mail; after the confirmation the address
    /// joins this installation. Returns `true` (the sign-up waits for the confirmation).
    @discardableResult
    public static func subscribe(email: String, language: String? = nil) async throws -> Bool {
        guard let e = current else { throw TTMailerError.notConfigured }
        return try await e.subscribe(email: email, language: language)
    }

    /// Call when the user taps a notification (`userNotificationCenter(_:didReceive:)` → `response.notification.request.content.userInfo`).
    /// Reports the open to TTMailer and returns the push's link, if it has one.
    @discardableResult
    public static func opened(_ userInfo: [AnyHashable: Any]) -> URL? {
        guard let e = current else { return nil }
        let link = linkOf(userInfo, key: e.linkKey)
        let token = userInfo["ttmToken"] as? String
        Task { _ = await e.opened(token.map { ["ttmToken": $0] } ?? [:]); await e.flushOpens() }
        return link
    }

    /// Removes this installation from TTMailer (its device; its contact too when it has no e-mail) and starts a new one.
    public static func reset() async throws {
        guard let e = current else { throw TTMailerError.notConfigured }
        try await e.reset()
    }

    /// Erases the user's contact in TTMailer (they deleted their account) and starts a new installation.
    public static func deleteContact() async throws {
        guard let e = current else { throw TTMailerError.notConfigured }
        try await e.deleteContact()
    }

    static func linkOf(_ userInfo: [AnyHashable: Any], key: String) -> URL? {
        guard let s = userInfo[key] as? String, let url = URL(string: s), url.scheme != nil else { return nil }
        return url
    }
}
