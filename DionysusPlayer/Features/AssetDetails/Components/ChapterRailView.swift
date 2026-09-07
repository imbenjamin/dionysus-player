import SwiftUI

/// The Chapters rail on a movie/episode detail page — a horizontal shelf of
/// chapter stills that deep-link straight into playback at that timestamp.
///
/// A sibling of `MediaRailView` rather than a reuse of it: every card in
/// that rail is a `MediaItem` wrapped in a `NavigationLink(value:
/// AppRoute.assetDetail(...))`, and a chapter is neither — it's a position
/// within the item already on screen, and tapping one starts playback
/// rather than pushing a destination. The tap is therefore a plain closure,
/// so each host page can build its own `PlaybackRequest` (live) or set its
/// own offline start position (`DownloadedAssetDetailView`) from it.
///
/// Deliberately *not* sized to match `LandscapeMediaCard` (220pt) the way
/// the "Included In"/"More Like This" rails below it are — at 220pt a
/// chapter tile showed barely one full card plus a sliver of the next,
/// which read as a single big tile rather than a scrollable shelf. Chapter
/// cards are smaller (see `ChapterCard.width`) specifically so ~2 full
/// cards plus a peek of a third are visible at once, the same "there's more
/// to scroll to" affordance `PosterCard`'s portrait rails already give for
/// free at their own (narrower) width.
struct ChapterRailView: View {
    let chapters: [Chapter]
    /// Fired with the tapped chapter — the host page turns it into a
    /// playback start position. Never a `NavigationLink`; see this type's
    /// own doc comment.
    var onSelect: (Chapter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chapters")
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                // `LazyHStack`, same reasoning as `MediaRailView`'s — a
                // feature-length movie can carry 30+ chapters, and a plain
                // `HStack` would fire every one of their image loads up
                // front regardless of what's actually on screen.
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(chapters) { chapter in
                        ChapterCard(chapter: chapter) { onSelect(chapter) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// One chapter tile: still frame, name, timestamp. A `Button`, not a
/// `NavigationLink` — see `ChapterRailView`'s doc comment.
struct ChapterCard: View {
    let chapter: Chapter
    /// 150pt, not `LandscapeMediaCard`'s 220pt — chosen (2026-09-03, direct
    /// user feedback against a live build) so a typical iPhone width shows
    /// two full cards plus a clear peek of a third, rather than one card and
    /// a barely-there sliver. See `ChapterRailView`'s own doc comment.
    var width: CGFloat = 150
    var action: () -> Void

    private var imageHeight: CGFloat { width * 9 / 16 }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                thumbnail
                    .frame(width: width, height: imageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.name)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    // A timecode, not localizable prose — same treatment
                    // `PlayerControlsOverlay`'s own timestamps get, per
                    // CLAUDE.md's localization rules.
                    Text(ChapterTimeFormatter.string(from: chapter.startSeconds))
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
            // Explicit label + `.ignore`, same pattern as `PosterCard` — the
            // raw timecode reads as disconnected digits on its own, so the
            // spoken label spells the position out instead.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                String(localized: "\(chapter.name), starts at \(ChapterTimeFormatter.spokenString(from: chapter.startSeconds))")
            )
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(.plain)
    }

    /// `file://` artwork (an offline download's stored still) goes through
    /// `LocalFileImage`, everything else through `AsyncRemoteImage` — see
    /// `Chapter.imageURL`'s doc comment and CLAUDE.md's image-loading split.
    /// A chapter with no image at all lands on `AsyncRemoteImage`'s `nil`-URL
    /// path, which settles straight to `MediaPlaceholderBox` with no
    /// shimmer — correct here, since a missing `imageTag` means there was
    /// never anything to fetch.
    @ViewBuilder
    private var thumbnail: some View {
        if let url = chapter.imageURL, url.isFileURL {
            LocalFileImage(
                url: url,
                targetSize: CGSize(width: width, height: imageHeight),
                placeholderSystemImage: "film"
            )
        } else {
            AsyncRemoteImage(url: chapter.imageURL, placeholderSystemImage: "film")
        }
    }
}

/// Shared chapter-timestamp formatting for the rail, the player's
/// current-chapter button, and the chapter picker — one implementation
/// rather than a third copy of `PlayerControlsOverlay`'s own private
/// `formatTime`/`spokenTime` pair, which stays private to that view for the
/// scrubber's own labels.
enum ChapterTimeFormatter {
    /// "12:34" / "1:02:03" — a bare timecode, deliberately not localized
    /// (industry-standard formatted data, per CLAUDE.md).
    static func string(from seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// The spoken-out counterpart for `.accessibilityLabel` use — same
    /// reasoning as `PlayerControlsOverlay.spokenTime`: VoiceOver reads a
    /// bare "1:02:03" as disconnected digits with no unit context.
    static func spokenString(from seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return String(localized: "the start") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        guard let result = formatter.string(from: seconds), !result.isEmpty else {
            return String(localized: "the start")
        }
        return result
    }
}
