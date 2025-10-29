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
    public var productsList: [Product] = []
    public private(set) var eligibilityCache: [EligibilityStatus] = []
    private var productIDs: [String] = []
    private init() {
        //Start a transaction listener as close to app launch as possible so you don't miss any transactions.
        updateListenerTask = listenForTransactions()
        
        Task {
            //During store initialization, request products from the App Store.
            
            
            //Deliver products that the customer purchases.
            await updateCustomerProductStatus()
        }
    }
    private var updateListenerTask: Task<Void, Error>? = nil
    // MARK: - Notification Name
    public static let didUpdateProStatusNotification = Notification.Name("didUpdateProStatusNotification")
    
    // MARK: - Configure
    public func configure(with ids: [String]) {
        self.productIDs = ids
    }
    deinit {
        updateListenerTask?.cancel()
    }
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            //Iterate through any transactions that don't come from a direct call to `purchase()`.
            for await result in Transaction.updates {
                do {
                    let transaction = try await self.checkVerified(result)
                    
                    //Deliver products to the user.
                    await self.updateCustomerProductStatus()
                    
                    //Always finish a transaction.
                    await transaction.finish()
                } catch {
                    //StoreKit has a transaction that fails verification. Don't deliver content to the user.
                    print("Transaction failed verification")
                }
            }
        }
    }
    func updateCustomerProductStatus() async {
        var lifeTimePurchase: [String] = []
        var purchasedSubscriptions: [String] = []
        
        //Iterate through all of the user's purchased products.
        for await result in Transaction.currentEntitlements {
            do {
                //Check whether the transaction is verified. If it isn’t, catch `failedVerification` error.
                let transaction = try checkVerified(result)
                //Check the `productType` of the transaction and get the corresponding product from the store.
                switch transaction.productType {
                case .nonConsumable:
                    if let car = productIDs.first(where: { $0 == transaction.productID }) {
                        lifeTimePurchase.append(car)
                    }
                case .nonRenewable:
                    break
                case .autoRenewable:
                    if let subscription = productIDs.first(where: { $0 == transaction.productID }) {
                        purchasedSubscriptions.append(subscription)
                    }
                default:
                    break
                }
            } catch {
                print()
            }
        }
        if purchasedSubscriptions.isEmpty{
            updateStatus(appUnlocked: false) // Save + notify
        }else if !purchasedSubscriptions.isEmpty{
            updateStatus(appUnlocked: true) // Save + notify
        }else if !lifeTimePurchase.isEmpty{
            updateStatus(appUnlocked: true) // Save + notify
        }else{
            updateStatus(appUnlocked: false)
        }
    }
    // MARK: - Load Products & Eligibility
    @discardableResult
    public func requestProducts() async throws -> [Product] {
        assert(!productIDs.isEmpty, "❌ No product IDs configured. Call configure(with:) before requesting products.")
        
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
                    
                    updateStatus(appUnlocked: true) // Save + notify
                    
                case .userCancelled, .pending:
                    updateStatus(appUnlocked: false)
                    
                default:
                    updateStatus(appUnlocked: false)
                }
            } catch {
                print("❌ Purchase failed: \(error)")
                updateStatus(appUnlocked: false)
            }
        }
    }
    public func restorePurchases() async -> (success: Bool, message: String, restoredProductIDs: [String]) {
        let restoredProductIDs: [String] = []
        
        do {
            // Step 1: Sync with App Store to get latest transaction history
            try await AppStore.sync()
            print("App Store sync completed")
            
            // Step 2: Check current entitlements (active purchases)
            for await verificationResult in Transaction.currentEntitlements {
                switch verificationResult {
                case .verified(let transaction):
                    // Check if purchase is still valid
                    if await isTransactionValid(transaction) {
                        updateStatus(appUnlocked: true)
                    } else {
                        updateStatus(appUnlocked: false)
                    }
                    // Always finish the transaction
                    await transaction.finish()
                    
                case .unverified(let transaction, let error):
                    print("Unverified transaction: \(transaction.productID), error: \(error)")
                    updateStatus(appUnlocked: false)
                }
            }
            print(restoredProductIDs)
            // Step 3: Return appropriate message
            if !restoredProductIDs.isEmpty {
                updateStatus(appUnlocked: false)
                return (true, "Successfully restored \(restoredProductIDs.count) purchase(s)", restoredProductIDs)
            } else {
                updateStatus(appUnlocked: false)
                return (true, "No previous purchases found", [])
            }
        } catch {
            updateStatus(appUnlocked: false)
            print("Restore purchases failed: \(error)")
            return (false, "Failed to restore purchases: \(error.localizedDescription)", [])
        }
    }
    // Helper function to validate transaction status
    private func isTransactionValid(_ transaction: Transaction) async -> Bool {
        // Check if purchase was revoked
        if transaction.revocationDate != nil {
            return false
        }
        
        // Check if subscription is expired (if applicable)
        if let expirationDate = transaction.expirationDate {
            if expirationDate < Date() {
                return false
            }
        }
        
        // Check if purchase is still within its validity period
        if let revocationDate = transaction.revocationDate {
            if revocationDate < Date() {
                return false
            }
        }
        
        // Additional check for subscription status
        if transaction.productType == .autoRenewable {
            return await checkSubscriptionStatus(transaction)
        }
        // For non-consumables and valid subscriptions
        return true
    }
    // Additional subscription status check
    private func checkSubscriptionStatus(_ transaction: Transaction) async -> Bool {
        // Get latest subscription status
        let statuses = await transaction.subscriptionStatus
        guard let status = statuses else { return false }
        
        switch status.state {
        case .subscribed, .inGracePeriod, .inBillingRetryPeriod:
            return true
        case .expired, .revoked:
            return false
        default:
            return false
        }
    }
    // MARK: - Helpers
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        //Check whether the JWS passes StoreKit verification.
        switch result {
        case .unverified:
            //StoreKit parses the JWS, but it fails verification.
            throw StoreError.failedVerification
        case .verified(let safe):
            //The result is verified. Return the unwrapped value.
            return safe
        }
    }
    public func sortByPrice(_ products: [Product]) -> [Product] {
        products.sorted(by: { return $0.price < $1.price })
    }
}

extension StorekitManager {
    public func checkProUser() -> Bool {
        return KeychainHelper.getBool(PremiumKey.UnlockApp.rawValue)
    }
    
    func updateStatus(appUnlocked: Bool) {
        KeychainHelper.save(appUnlocked, key: PremiumKey.UnlockApp.rawValue)
        
        // Notify observers
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
