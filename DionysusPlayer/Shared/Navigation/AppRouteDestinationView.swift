import SwiftUI

/// Maps an `AppRoute` to its destination view. Registered once per tab's
/// `NavigationStack` via `.navigationDestination(for: AppRoute.self)`.
struct AppRouteDestinationView: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .collection(let query):
            CollectionGridView(query: query)
        case .assetDetail(let itemID):
            AssetDetailView(itemID: itemID)
        }
    }
}
