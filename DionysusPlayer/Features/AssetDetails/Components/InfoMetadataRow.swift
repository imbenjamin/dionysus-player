import SwiftUI

/// Year (range) — or, for an individual episode, its exact air date, e.g.
/// "1 Aug 2026" (see `MediaItem.metadataDateText`) — age rating, duration,
/// and rating on the first line; a dot-separated line of resolution/
/// dynamic-range/audio-format/accessibility badges on the second — the
/// common metadata shown on every detail page. Genres moved to the "About"
/// tab (`DetailTabsView`), above the synopsis; badges took their old spot
/// on the second line.
struct InfoMetadataRow: View {
    let item: MediaItem

    /// Centered, and stretched to fill whatever width it's given, unlike
    /// everything below the Play row on these pages — which stays
    /// leading-aligned. These two lines are a caption for the hero
    /// directly above them (whose logo/title is itself centered), not the
    /// start of the page's reading column, so centering groups them with
    /// the artwork rather than with the prose further down. Applies on
    /// every device, not just regular width: the hero is centered on
    /// iPhone too.
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            HStack(spacing: 10) {
                if let date = item.metadataDateText {
                    Text(date).accessibilityLabel(String(localized: "Released: \(date)"))
                }

                if let rating = item.ageRating {
                    Text(rating)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                        .accessibilityLabel(String(localized: "Age Rating: \(rating)"))
                }

                if let duration = item.durationText {
                    // "1h 32m" gets misheard by VoiceOver as "One H Thirty
                    // Two Meters" — see `MediaItem.durationAccessibilityText`'s
                    // doc comment.
                    Text(duration)
                        .accessibilityLabel(String(localized: "Duration: \(item.durationAccessibilityText ?? duration)"))
                }

                if let communityRating = item.communityRating {
                    // `Label`'s default icon/title spacing reads as too wide
                    // here — closer to the two being separate items than one
                    // "★ 4.8" rating — so a plain HStack with an explicit,
                    // tight spacing instead.
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                        Text(String(format: "%.1f", communityRating))
                    }
                    // `.ignore` — without it, the star glyph and number read
                    // as two separate VoiceOver stops ("star.fill, image"
                    // then the bare number). One combined "Rated: 7.9 stars"
                    // instead.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        String(localized: "Rated: \(String(format: "%.1f", communityRating)) stars")
                    )
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !item.metadataBadges.isEmpty {
                Text(item.metadataBadges.joined(separator: " \u{00B7} "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        String(localized: "Formats: \(item.metadataBadges.map(Self.accessibilityBadge).joined(separator: ", "))")
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Expands the handful of badges VoiceOver can't be expected to read
    /// naturally on their own — everything else (4K, HD, DTS, Dolby Atmos,
    /// ...) already reads fine as-is and passes through unchanged.
    /// `DownloadedInfoMetadataRow` has its own identical copy rather than
    /// sharing this one — same "small pure duplication, documented why"
    /// shape `MediaItem`/`DownloadedItem`'s own `durationText` pair already
    /// uses elsewhere in this codebase.
    fileprivate static func accessibilityBadge(_ badge: String) -> String {
        switch badge {
        case "CC": String(localized: "Closed Captions")
        case "DD+": String(localized: "Dolby Digital Plus")
        case "DD": String(localized: "Dolby Digital")
        default: badge
        }
    }
}
