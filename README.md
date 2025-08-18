**StorekitManager 🍏💰**

StorekitManager is a lightweight Swift library for iOS and macOS that simplifies in-app purchases using StoreKit 2. It handles product fetching, subscription eligibility checks, and provides a smooth integration experience for your apps.

**Features ✨**
- 🎯 Support for iOS 16+ and macOS 13+
- 🛒 Fetch and manage in-app purchases and subscriptions
- ⚡ Automatic fallback to default product list if the user doesn’t provide one
- 🔔 Notifies developers when no product list is provided
- 🔐 Easy handling of subscription eligibility and introductory offers
- ✅ Fully written in Swift using StoreKit 2 APIs

**Installation 💻**
- Swift Package Manager (SPM)
- Add the package to your project via Xcode:
  https://github.com/MuhammadAshir01/StorekitManager
  
**Usage 📲**
- Import the Library
- import StorekitManager

**Load Products**

Task {

    await StorekitManager.shared.loadProducts(from: ["com.example.app.product1", "com.example.app.product2"])
}

⚠️ If the product list is not provided, the library will generate a crash.

**Check Subscription Eligibility**

let eligibility = await StorekitManager.shared.checkEligibility(for: "com.example.app.subscription")
if eligibility {
    print("User is eligible for the introductory offer")
}

**Platforms Supported 🖥️📱**
- iOS 16+
- macOS 13+
  
**Contributing 🤝**

Contributions are welcome! Feel free to open issues or submit pull requests.
