import Foundation
import StoreKit

/// "Buy me a coffee": a consumable in-app purchase that can be bought any number of times.
/// It unlocks nothing — TeslaNav is free — it's a way to say thanks. Apple handles the payment,
/// so there is no backend and nothing to keep in sync.
@MainActor
final class Tips: ObservableObject {
    static let coffeeID = "com.hakobhakobyan.teslanav.coffee"

    @Published private(set) var product: Product?
    @Published private(set) var purchasing = false
    /// Shown after a successful tip; also remembered so the card can keep saying thanks.
    @Published private(set) var thanked = UserDefaults.standard.integer(forKey: "teslanav.coffees") > 0
    /// Set when a purchase fails for a reason worth showing; user cancellation is not one.
    @Published private(set) var failure: String?

    private var updates: Task<Void, Never>?

    init() {
        // Ask to Buy approvals arrive later, outside the purchase call; finish them too.
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                guard let transaction = try? update.payloadValue else { continue }
                await transaction.finish()
                if transaction.productID == Self.coffeeID { self?.recordCoffee() }
            }
        }
    }

    func load() async {
        product = try? await Product.products(for: [Self.coffeeID]).first
    }

    /// The price as the App Store formats it for this storefront, e.g. "$2.99" or "2,99 €".
    var displayPrice: String? { product?.displayPrice }

    func buyCoffee() async {
        guard let product, !purchasing else { return }
        purchasing = true
        failure = nil
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if let transaction = try? verification.payloadValue {
                    await transaction.finish()
                    recordCoffee()
                }
            case .userCancelled:
                break
            case .pending:
                failure = "Waiting for approval. Thank you!"
            @unknown default:
                break
            }
        } catch {
            failure = "The purchase didn't go through. \(error.localizedDescription)"
        }
    }

    private func recordCoffee() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: "teslanav.coffees") + 1, forKey: "teslanav.coffees")
        thanked = true
    }
}
