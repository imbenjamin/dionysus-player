import Foundation

/// What the sidebar lists for the user's libraries (decided 2026-09-29): each
/// library as its own entry up to `foldThreshold`, one expandable "Libraries"
/// entry above it. Counted after the audio suppression, since a Music library
/// is never shown.
enum TVSidebarLayout {
    static let foldThreshold = 5

    enum Libraries: Equatable {
        case none
        case inline([MediaItem])
        case folded([MediaItem])
    }

    static func libraries(_ libraries: [MediaItem]) -> Libraries {
        // AUDIO SUPPRESSION: as Home's library rail.
        let shown = libraries.filter { !$0.isAudioLibrary }
        if shown.isEmpty { return .none }
        return shown.count > foldThreshold ? .folded(shown) : .inline(shown)
    }

    /// One focusable row of the custom sidebar (Task 6b).
    enum Row: Hashable {
        case profile
        case home
        case search
        case librariesGroup
        case library(String)
    }

    /// Collapsed, a row that can't take focus is hidden from VoiceOver, which
    /// otherwise read every dimmed row after each tile (M5).
    static func isHiddenFromAccessibility(_ row: Row, isExpanded: Bool, focusable: Set<Row>) -> Bool {
        !isExpanded && !focusable.contains(row)
    }

    /// The sidebar's rows, top to bottom: Profile pinned at the top, as in
    /// Apple's TV app, then Home and Search, then each library, or, above
    /// `foldThreshold`, the Libraries row with its libraries only while it's
    /// expanded.
    static func rows(libraries: [MediaItem], librariesExpanded: Bool) -> [Row] {
        let top: [Row] = [.profile, .home, .search]
        switch self.libraries(libraries) {
        case .none:
            return top
        case .inline(let shown):
            return top + shown.map { .library($0.id) }
        case .folded(let shown):
            return top + [.librariesGroup] + (librariesExpanded ? shown.map { .library($0.id) } : [])
        }
    }

    /// A library's symbol, from its content type: Jellyfin sends no icon, and
    /// a library can be called anything, but each has the "Content type" its
    /// admin chose when creating it (`CollectionType`). Mixed content, and any
    /// type this list doesn't know, is a folder.
    static func systemImage(forCollectionType type: String?) -> String {
        switch type {
        case JellyfinCollectionType.movies: "film"
        case JellyfinCollectionType.tvShows: "tv"
        case JellyfinCollectionType.boxSets: "square.stack"
        case JellyfinCollectionType.playlists: "list.bullet.rectangle"
        case "homevideos": "video"
        case "musicvideos": "music.note.tv"
        case "photos": "photo.on.rectangle"
        case "books": "book"
        case "livetv": "dot.radiowaves.left.and.right"
        default: "folder"
        }
    }

    /// The same query iOS's library rail opens a library with.
    static func query(for library: MediaItem) -> CollectionQuery {
        CollectionQuery(title: library.name, parentID: library.id, includeItemTypes: library.libraryContentItemTypes)
    }
}
