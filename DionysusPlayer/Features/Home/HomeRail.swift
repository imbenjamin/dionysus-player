import Foundation

/// The Home screen's top menu bar sections. Order matches the top bar.
enum HomeCategory: String, CaseIterable, Identifiable {
    case movies = "Movies"
    case series = "Series"
    case collections = "Collections"

    var id: String { rawValue }
}

/// A rail plus which top-bar category it belongs to. `category == nil`
/// means the rail is pinned and shown under every category (e.g. "Continue
/// Watching").
struct HomeRail: Identifiable {
    var id: String { rail.id }
    var category: HomeCategory?
    var rail: MediaCollectionRail
}
