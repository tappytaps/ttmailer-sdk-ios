import Foundation

/// What the SDK tells TTMailer about the user's purchases (TTM-585): the premium's end (or lifetime), its kind and
/// start, and every one-time product the user owns (each a tag `koupeno_<product>` in TTMailer).
public struct PremiumReport: Codable, Equatable, Sendable {
    public var until: Date?
    public var lifetime: Bool
    public var kind: String?
    public var startedAt: Date?
    /// nil = not reported (the products' tags stay as they are); [] = owns none.
    public var products: [String]?

    public init(until: Date?, lifetime: Bool, kind: String?, startedAt: Date?, products: [String]?) {
        self.until = until; self.lifetime = lifetime; self.kind = kind; self.startedAt = startedAt; self.products = products
    }

    var json: [String: Any] {
        var b: [String: Any] = [:]
        if lifetime { b["lifetime"] = true } else if let until { b["until"] = Engine.iso(until) }
        if let kind { b["kind"] = kind }
        if let startedAt { b["startedAt"] = Engine.iso(startedAt) }
        if let products { b["products"] = products }
        return b
    }
}

/// One purchase the store says the user has now (StoreKit's current entitlements, Play Billing's purchases).
struct Entitlement: Equatable, Sendable {
    enum Kind: Sendable { case subscription, oneTime }
    let productId: String
    let kind: Kind
    let expiresAt: Date?
    let originalPurchaseAt: Date?
    let trial: Bool
}

extension PremiumReport {
    /// The report for what the store says now, given the last one sent. nil = nothing to tell (a user who never paid).
    /// - A lifetime product (`lifetimeProducts`) → lifetime; else the active subscription ending last → until its end.
    /// - Nothing active, but the last report was premium → it ended now (a refund, a cancelled trial); kind and start stay.
    static func from(_ entitlements: [Entitlement], lifetimeProducts: Set<String>, previous: PremiumReport?, now: Date) -> PremiumReport? {
        let products = Array(Set(entitlements.filter { $0.kind == .oneTime }.map(\.productId))).sorted()
        if let life = entitlements.first(where: { $0.kind == .oneTime && lifetimeProducts.contains($0.productId) }) {
            return PremiumReport(until: nil, lifetime: true, kind: "lifetime", startedAt: life.originalPurchaseAt, products: products)
        }
        let subs = entitlements.filter { $0.kind == .subscription && ($0.expiresAt.map { $0 > now } ?? false) }
        if let sub = subs.max(by: { $0.expiresAt! < $1.expiresAt! }) {
            return PremiumReport(until: sub.expiresAt, lifetime: false, kind: sub.trial ? "trial" : "paid", startedAt: sub.originalPurchaseAt, products: products)
        }
        if let prev = previous, prev.lifetime || prev.until != nil {
            let wasActive = prev.lifetime || (prev.until.map { $0 > now } ?? false)
            return PremiumReport(until: wasActive ? now : prev.until, lifetime: false, kind: prev.kind, startedAt: prev.startedAt, products: products)
        }
        if products.isEmpty && (previous?.products ?? []).isEmpty { return nil }
        return PremiumReport(until: nil, lifetime: false, kind: nil, startedAt: nil, products: products)
    }
}
