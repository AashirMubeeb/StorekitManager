import Foundation
import StoreKit

enum StoreError: Error {
    case failedVerification
    case noProductIDsConfigured
}

private enum PremiumKey: String {
    case UnlockApp = "UnlockAI"
}

public struct EligibilityStatus {
    public let productID: String
    public let isEligible: Bool
}

@MainActor
public class StorekitManager: ObservableObject {

    public static let shared = StorekitManager()

    // MARK: - Properties
    @Published public private(set) var isUnlocked: Bool = false
    public var productsList: [Product] = []
    public private(set) var eligibilityCache: [EligibilityStatus] = []
    private var productIDs: [String] = []
    private var isConfigured = false

    private init() {
        // Restore last known cached status immediately so the UI has something
        // correct to show before the async entitlement check completes.
        isUnlocked = KeychainHelper.getBool(PremiumKey.UnlockApp.rawValue)

        // Start a transaction listener as close to app launch as possible so you
        // don't miss any transactions.
        updateListenerTask = listenForTransactions()
    }

    private var updateListenerTask: Task<Void, Error>? = nil

    // MARK: - Notification Name
    public static let didUpdateProStatusNotification = Notification.Name("didUpdateProStatusNotification")

    // MARK: - Configure
    /// Call this once, as early as possible (e.g. app launch), before requesting
    /// products or checking entitlements. Triggers an immediate entitlement sync.
    public func configure(with ids: [String]) {
        self.productIDs = ids
        self.isConfigured = true

        Task {
            await updateCustomerProductStatus()
        }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            // Iterate through any transactions that don't come from a direct call to `purchase()`.
            for await result in Transaction.updates {
                do {
                    let transaction = try await self.checkVerified(result)

                    // Re-sync entitlement status from the source of truth.
                    await self.updateCustomerProductStatus()

                    // Always finish a transaction.
                    await transaction.finish()
                } catch {
                    // StoreKit has a transaction that fails verification. Don't deliver content to the user.
                    print("Transaction failed verification")
                }
            }
        }
    }

    /// Recomputes unlocked status from `Transaction.currentEntitlements` (the
    /// single source of truth) and persists/notifies only if it actually changed.
    func updateCustomerProductStatus() async {
        // Guard against running before `configure(with:)` has set the product
        // IDs — otherwise every entitlement would be filtered out below and we'd
        // incorrectly persist `false`, clobbering a real unlocked state.
        guard isConfigured, !productIDs.isEmpty else {
            print("⚠️ updateCustomerProductStatus called before configure(with:) — skipping.")
            return
        }

        var unlocked = false

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                guard productIDs.contains(transaction.productID) else {
                    continue
                }

                switch transaction.productType {
                case .nonConsumable:
                    unlocked = true

                case .nonRenewable:
                    // Treat like nonConsumable if you sell non-renewing passes;
                    // otherwise leave as not contributing to unlock.
                    break

                case .autoRenewable:
                    if isTransactionValid(transaction) {
                        unlocked = true
                    }

                default:
                    break
                }

                if unlocked {
                    break
                }

            } catch {
                print("Transaction verification failed: \(error)")
            }
        }

        updateStatus(appUnlocked: unlocked)
    }

    // MARK: - Load Products & Eligibility
    @discardableResult
    public func requestProducts() async throws -> [Product] {
        guard !productIDs.isEmpty else {
            throw StoreError.noProductIDsConfigured
        }

        productsList = try await Product.products(for: productIDs)

        // Update eligibility cache
        eligibilityCache = []
        for product in productsList {
            let isEligible: Bool = await {
                guard let subscription = product.subscription,
                      subscription.introductoryOffer != nil else { return false }
                return await subscription.isEligibleForIntroOffer
            }()
            eligibilityCache.append(EligibilityStatus(productID: product.id, isEligible: isEligible))
        }

        return productsList
    }

    // MARK: - Purchase
    public func purchase(_ product: Product) {
        Task {
            do {
                let result = try await product.purchase()

                switch result {
                case .success(let verification):
                    let transaction = try checkVerified(verification)
                    await transaction.finish()

                    // Re-sync from entitlements rather than blindly forcing `true` —
                    // this keeps the cached state consistent with reality.
                    await updateCustomerProductStatus()

                case .userCancelled, .pending:
                    // IMPORTANT: do NOT force `false` here. Cancelling or a pending
                    // purchase says nothing about the user's *existing* entitlement.
                    // Forcing false here was the bug that could lock out an already
                    //-subscribed user who cancelled an unrelated purchase attempt.
                    break

                @unknown default:
                    break
                }
            } catch {
                print("❌ Purchase failed: \(error)")
                // Same reasoning as above: don't touch status on a failed purchase
                // attempt. If you want to be safe, re-sync instead of forcing false:
                await updateCustomerProductStatus()
            }
        }
    }

    public func restorePurchases() async -> (success: Bool, message: String, restoredProductIDs: [String]) {
        // AppStore.sync() is best-effort — if it fails (e.g. no network) we still
        // want to check whatever entitlements are already known locally, so we
        // don't bail out of the whole function on a sync failure.
        do {
            try await AppStore.sync()
        } catch {
            print("AppStore.sync() failed (continuing with local entitlements): \(error)")
        }

        var restoredProductIDs: [String] = []
        var unlocked = false

        for await verificationResult in Transaction.currentEntitlements {
            switch verificationResult {
            case .verified(let transaction):
                guard productIDs.contains(transaction.productID) else {
                    await transaction.finish()
                    continue
                }

                if isTransactionValid(transaction) {
                    unlocked = true
                    restoredProductIDs.append(transaction.productID)
                }

                await transaction.finish()

            case .unverified(let productID, let error):
                print("Unverified transaction during restore, error: \(error)")
                _ = productID
            }
        }

        // Set status exactly once, based on the actual result of the loop above —
        // the original bug unconditionally forced `false` here regardless of what
        // was found.
        updateStatus(appUnlocked: unlocked)

        if !restoredProductIDs.isEmpty {
            return (true, "Successfully restored \(restoredProductIDs.count) purchase(s)", restoredProductIDs)
        } else {
            return (true, "No previous purchases found", [])
        }
    }

    // Helper function to validate transaction status.
    // Note: Transaction.currentEntitlements already excludes expired/revoked
    // transactions in the normal case, but we double-check defensively.
    private func isTransactionValid(_ transaction: Transaction) -> Bool {
        if transaction.revocationDate != nil {
            return false
        }

        if let expirationDate = transaction.expirationDate, expirationDate < Date() {
            return false
        }

        return true
    }

    // MARK: - Helpers
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        // Check whether the JWS passes StoreKit verification.
        switch result {
        case .unverified:
            // StoreKit parses the JWS, but it fails verification.
            throw StoreError.failedVerification
        case .verified(let safe):
            // The result is verified. Return the unwrapped value.
            return safe
        }
    }

    public func sortByPrice(_ products: [Product]) -> [Product] {
        products.sorted(by: { $0.price < $1.price })
    }
}

extension StorekitManager {
    public func checkProUser() -> Bool {
        return isUnlocked
    }

    func updateStatus(appUnlocked: Bool) {
        // Only persist + notify when the value actually changes, to avoid
        // redundant Keychain writes and unnecessary notification spam.
        guard isUnlocked != appUnlocked else { return }

        isUnlocked = appUnlocked
        KeychainHelper.save(appUnlocked, key: PremiumKey.UnlockApp.rawValue)

        NotificationCenter.default.post(
            name: StorekitManager.didUpdateProStatusNotification,
            object: nil,
            userInfo: nil
        )
    }

    /// Checks if a product is eligible for introductory offers.
    /// - Parameter productID: The ID of the product to check.
    /// - Returns: `true` if eligible, otherwise `false`.
    public func isProductEligible(productID: String) -> Bool {
        guard !eligibilityCache.isEmpty else { return false }
        return eligibilityCache.first(where: { $0.productID == productID })?.isEligible ?? false
    }
}

