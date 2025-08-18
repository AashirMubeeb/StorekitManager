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
    private init() {}
    
    // MARK: - Notification Name
    public static let didUpdateProStatusNotification = Notification.Name("didUpdateProStatusNotification")
    
    // MARK: - Configure
    public func configure(with ids: [String]) {
        self.productIDs = ids
    }
    
    // MARK: - Load Products & Eligibility
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
    public func purchase(_ product: Product, completion: @escaping (Bool) -> Void) {
        Task {
            do {
                let result = try await product.purchase()
                
                switch result {
                case .success(let verification):
                    let transaction = try checkVerified(verification)
                    await transaction.finish()
                    
                    updateStatus(appUnlocked: true) // Save + notify
                    completion(true)
                    
                case .userCancelled, .pending:
                    completion(false)
                    
                default:
                    completion(false)
                }
            } catch {
                print("❌ Purchase failed: \(error)")
                completion(false)
            }
        }
    }
    
    // MARK: - Restore Purchases
    public func restorePurchases(completion: @escaping (Bool) -> Void) {
        Task {
            var restored = false
            for await result in Transaction.currentEntitlements {
                do {
                    _ = try checkVerified(result)
                    updateStatus(appUnlocked: true)
                    restored = true
                } catch {
                    print("⚠️ Verification failed during restore: \(error)")
                }
            }
            completion(restored)
        }
    }
    
    // MARK: - Helpers
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
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
