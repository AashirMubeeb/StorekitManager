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
    var productID: String
    var isEligible: Bool
}

@MainActor
public class StorekitManager: ObservableObject {
    public static let shared = StorekitManager()
    private(set) var productsList: [Product] = []
    private var productIDs: [String] = []
    private init() {}
    
    // MARK: - Notification Name
    public static let didUpdateProStatusNotification = Notification.Name("didUpdateProStatusNotification")
    
    // MARK: - Configure with Product IDs
    public func configure(with ids: [String]) {
        self.productIDs = ids
    }
    // MARK: - Load Products
    public func requestProducts() async throws -> [Product] {
        guard !productIDs.isEmpty else {
            throw StoreError.noProductIDsConfigured
        }
        productsList = try await Product.products(for: productIDs)
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
                    
                    updateStatus(appUnlocked: true) // 🔑 Save + notify
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
                    updateStatus(appUnlocked: true) // 🔑 Save + notify
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
        
        // 📢 Notify observers
        NotificationCenter.default.post(
            name: StorekitManager.didUpdateProStatusNotification,
            object: nil,
            userInfo: nil
        )
    }
}

