import Foundation
import StoreKit

@Observable
final class IAPManager {
    static let shared = IAPManager()

    static let lifetimeProductID = "com.perrisaquino.reserch.lifetime"
    static let monthlyProductID  = "com.perrisaquino.reserch.monthly"
    static let allProductIDs     = [lifetimeProductID, monthlyProductID]

    var products: [Product] = []
    var isPro: Bool = false
    var purchaseError: String?

    private var updatesTask: Task<Void, Never>?

    private init() {}

    var lifetimeProduct: Product? { products.first { $0.id == Self.lifetimeProductID } }
    var monthlyProduct:  Product? { products.first { $0.id == Self.monthlyProductID  } }

    func start() {
        if updatesTask == nil {
            updatesTask = Task.detached { [weak self] in
                for await update in Transaction.updates {
                    await self?.handle(update)
                }
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    @MainActor
    func loadProducts() async {
        print("[IAP] loadProducts: starting")
        do {
            let fetched = try await Product.products(for: Self.allProductIDs)
            products = fetched.sorted { lhs, _ in lhs.id == Self.lifetimeProductID }
            print("[IAP] loadProducts: got \(products.count) products")
        } catch {
            print("[IAP] loadProducts failed: \(error)")
            purchaseError = "Couldn't load products. Check your connection."
        }
    }

    @MainActor
    func refreshEntitlements() async {
        var pro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result, Self.allProductIDs.contains(txn.productID) {
                if let revoked = txn.revocationDate, revoked <= Date() { continue }
                if let expires = txn.expirationDate, expires <= Date() { continue }
                pro = true
            }
        }
        isPro = pro
    }

    @MainActor
    func purchase(_ product: Product) async {
        purchaseError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let txn) = verification {
                    await txn.finish()
                    await refreshEntitlements()
                } else {
                    purchaseError = "Purchase could not be verified."
                }
            case .userCancelled:
                break
            case .pending:
                purchaseError = "Purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    @MainActor
    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func handle(_ result: VerificationResult<Transaction>) async {
        if case .verified(let txn) = result {
            await txn.finish()
            await refreshEntitlements()
        }
    }

    #if DEBUG
    @MainActor
    func debugSimulatePurchase() {
        NSLog("[IAP] DEBUG simulating purchase — flipping isPro = true")
        isPro = true
    }

    @MainActor
    func debugRevertPurchase() {
        NSLog("[IAP] DEBUG revert — flipping isPro = false")
        isPro = false
    }
    #endif
}
