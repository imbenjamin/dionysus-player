import Foundation

/// A `dionysus://item` link's `season=` and `section=` (#406), applied by
/// the title's page once it has loaded: a show opens on that season, and any
/// page scrolls to that section (on the Apple TV, focus goes to it). What the
/// page doesn't have is said; the page opens as usual.
extension DeepLink.ItemOptions {
    var isEmpty: Bool { season == nil && section == nil }

    /// The season the link names among a show's: its id, or its number as
    /// shown ("Season 2", "0" for Specials).
    static func seasonID(for value: String, in seasons: [MediaItem]) -> String? {
        if let season = seasons.first(where: { $0.id == value }) { return season.id }
        guard let number = Int(value) else { return nil }
        return seasons.first { $0.dto.indexNumber == number }?.id
    }

    /// What a page says when the link names a season it doesn't have.
    static func missingSeasonNotice(_ value: String, isShow: Bool) -> String {
        isShow
            ? String(localized: "This show has no season \(value).")
            : String(localized: "Only a show has seasons.")
    }
}

extension DeepLink.ItemOptions.Section {
    /// What a page says when it doesn't have this section.
    var missingNotice: String {
        switch self {
        case .cast: String(localized: "This title has no cast listed.")
        case .chapters: String(localized: "This title has no chapters to show.")
        case .details: String(localized: "This title has no details to show.")
        case .similar: String(localized: "There's nothing like this title yet.")
        }
    }
}

extension DeepLink.Issue {
    /// What an item link says about a part it couldn't read; nil for a part
    /// that isn't about a title's page.
    var itemNotice: String? {
        switch self {
        case .unknownSection: String(localized: "Couldn't read the section.")
        case .unreadableStartTime, .unreadableChapter, .unreadableAudio, .unreadableSubtitle,
             .unknownSort, .unknownOrder, .unknownFilter, .unknownMode, .unreadableBitrate: nil
        }
    }
}
