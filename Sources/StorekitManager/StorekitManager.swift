import Foundation
import StoreKit
import Combine

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
    
    // Thread-safe flag using dispatch queue
    private static let listenerQueue = DispatchQueue(label: "com.app.storekit.listener")
    private static var _isListenerActive = false
    private static var isListenerActive: Bool {
        listenerQueue.sync { _isListenerActive }
    }
    
    private static func setIsListenerActive(_ value: Bool) {
        listenerQueue.sync { _isListenerActive = value }
    }
    
    private var hasCalledUpdateCustomerProductStatus = false
    
    private init() {
        // Only start listener once
        guard !Self.isListenerActive else { return }
        Self.setIsListenerActive(true)
        
        updateListenerTask = listenForTransactions()
        
        Task {
            // Deliver initial products that the customer purchases.
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
        //Self.setIsListenerActive(false)
    }
    
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            // Iterate through any transactions that don't come from a direct call to `purchase()`.
            for await result in Transaction.updates {
                do {
                    let transaction = try await self.checkVerified(result)
                    
                    // Deliver products to the user - ensure this only processes once
                    await self.processTransactionUpdate(transaction)
                    
                    // Always finish a transaction.
                    await transaction.finish()
                } catch {
                    // StoreKit has a transaction that fails verification.
                    print("Transaction failed verification: \(error)")
                }
            }
        }
    }
    
    // Separate method to handle transaction updates
    private func processTransactionUpdate(_ transaction: Transaction) async {
        // Check if we already processed this transaction
        if !hasCalledUpdateCustomerProductStatus {
            hasCalledUpdateCustomerProductStatus = true
            
            await self.updateCustomerProductStatus()
            
            // Reset flag after processing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.hasCalledUpdateCustomerProductStatus = false
            }
        }
    }
    
    func updateCustomerProductStatus() async {
        var lifeTimePurchase: [String] = []
        var purchasedSubscriptions: [String] = []
        
        // Iterate through all of the user's purchased products.
        for await result in Transaction.currentEntitlements {
            do {
                // Check whether the transaction is verified.
                let transaction = try checkVerified(result)
                
                // Check the `productType` of the transaction
                switch transaction.productType {
                case .nonConsumable:
                    if productIDs.contains(transaction.productID) {
                        lifeTimePurchase.append(transaction.productID)
                    }
                case .autoRenewable:
                    if productIDs.contains(transaction.productID) {
                        // Check if subscription is still valid
                        if await isTransactionValid(transaction) {
                            purchasedSubscriptions.append(transaction.productID)
                        }
                    }
                default:
                    break
                }
            } catch {
                print("Transaction verification failed: \(error)")
            }
        }
        
        // Determine final status
        var isUnlocked = false
        
        if !lifeTimePurchase.isEmpty {
            isUnlocked = true
        } else if !purchasedSubscriptions.isEmpty {
            isUnlocked = true
        }
        
        // Only update once with the final status
        updateStatus(appUnlocked: isUnlocked)
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
    public func purchase(_ product: Product) async -> Bool {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                // Immediately update status after purchase
                await updateCustomerProductStatus()
                return true
                
            case .userCancelled, .pending:
                NotificationCenter.default.post(
                    name: StorekitManager.didUpdateProStatusNotification,
                    object: false)
                return false
                
            @unknown default:
                NotificationCenter.default.post(
                    name: StorekitManager.didUpdateProStatusNotification,
                    object: false)
                return false
            }
        } catch {
            print("❌ Purchase failed: \(error)")
            return false
        }
    }
    
    public func restorePurchases() async -> (success: Bool, message: String, restoredProductIDs: [String]) {
        var restoredProductIDs: [String] = []
        
        do {
            // Step 1: Sync with App Store
            try await AppStore.sync()
            
            // Step 2: Check current entitlements
            for await verificationResult in Transaction.currentEntitlements {
                switch verificationResult {
                case .verified(let transaction):
                    if await isTransactionValid(transaction) {
                        restoredProductIDs.append(transaction.productID)
                    }
                    await transaction.finish()
                    
                case .unverified:
                    continue
                }
            }
            
            // Step 3: Update status based on restored purchases
            await updateCustomerProductStatus()
            
            // Step 4: Return appropriate message
            if !restoredProductIDs.isEmpty {
                return (true, "Successfully restored \(restoredProductIDs.count) purchase(s)", restoredProductIDs)
            } else {
                return (true, "No previous purchases found", [])
            }
        } catch {
            NotificationCenter.default.post(
                name: StorekitManager.didUpdateProStatusNotification,
                object: false)
            return (false, "Failed to restore purchases: \(error.localizedDescription)", [])
        }
    }
    
    // Helper function to validate transaction status
    private func isTransactionValid(_ transaction: Transaction) async -> Bool {
        // Check if purchase was revoked
        if transaction.revocationDate != nil {
            return false
        }
        
        // Check if subscription is expired
        if let expirationDate = transaction.expirationDate {
            return expirationDate > Date()
        }
        
        // For non-consumables and valid subscriptions
        return true
    }
    
    // MARK: - Helpers
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
    
    public func sortByPrice(_ products: [Product]) -> [Product] {
        products.sorted(by: { return $0.price < $1.price })
    }
}

// MARK: - Premium Status Management
extension StorekitManager {
    public func checkProUser() -> Bool {
        return KeychainHelper.getBool(PremiumKey.UnlockApp.rawValue)
    }
    
    func updateStatus(appUnlocked: Bool) {
        let currentStatus = KeychainHelper.getBool(PremiumKey.UnlockApp.rawValue)
        
        // Only update and notify if status changed
        if currentStatus != appUnlocked {
            KeychainHelper.save(appUnlocked, key: PremiumKey.UnlockApp.rawValue)
            
            // Notify observers
            NotificationCenter.default.post(
                name: StorekitManager.didUpdateProStatusNotification,
                object: appUnlocked
            )
            
            print("Premium status updated: \(appUnlocked ? "PREMIUM" : "NOT PREMIUM")")
        }
    }
    
    /// Checks if a product is eligible for introductory offers.
    public func isProductEligible(productID: String) -> Bool {
        return eligibilityCache.first(where: { $0.productID == productID })?.isEligible ?? false
    }
}

