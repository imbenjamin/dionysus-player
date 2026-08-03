import Foundation

/// Push destinations shared by every tab's `NavigationStack`.
enum AppRoute: Hashable {
    case collection(CollectionQuery)
    case assetDetail(itemID: String)
}
