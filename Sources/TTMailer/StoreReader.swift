#if canImport(StoreKit)
import Foundation
import StoreKit

/// Reads the user's purchases from StoreKit 2 for the automatic premium (TTM-585). Only what StoreKit verified on the
/// device; nothing is finished or changed: the app keeps handling its own transactions.
@available(iOS 15.0, macOS 12.0, *)
enum StoreReader {
    static func entitlements() async -> [Entitlement] {
        var out: [Entitlement] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            switch t.productType {
            case .autoRenewable:
                out.append(Entitlement(productId: t.productID, kind: .subscription, expiresAt: t.expirationDate,
                                       originalPurchaseAt: t.originalPurchaseDate, trial: isTrial(t)))
            case .nonConsumable, .nonRenewable:
                out.append(Entitlement(productId: t.productID, kind: t.productType == .nonConsumable ? .oneTime : .nonRenewing, expiresAt: nil,
                                       originalPurchaseAt: t.originalPurchaseDate, trial: false))
            default:
                continue
            }
        }
        return out
    }

    static func isTrial(_ t: Transaction) -> Bool {
        if #available(iOS 17.2, macOS 14.2, *) { return t.offer?.paymentMode == .freeTrial }
        return t.offerType == .introductory
    }

    /// Calls `changed` on every new transaction (a purchase, a renewal, a refund) until the task is cancelled.
    static func observe(_ changed: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task.detached {
            for await _ in Transaction.updates { await changed() }
        }
    }
}
#endif
