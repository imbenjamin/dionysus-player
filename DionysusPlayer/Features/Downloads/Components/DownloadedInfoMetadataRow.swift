import SwiftUI

/// The offline counterpart to `InfoMetadataRow` — same two-line
/// composition (year-or-date/rating/duration/community-rating, then a
/// dot-separated badges line), sourced from `DownloadedItem`/`.metadata`
/// rather than a live `MediaItem`. Badges differ slightly from the live
/// page's own `MediaItem.metadataBadges`: no audio-format/accessibility
/// badges (nothing here varies per download the way it does live), but
/// adds the actual on-disk file size, which only makes sense for a
/// download. Like the live page, an episode download shows its exact air
/// date here (`DownloadedItem.metadataDateText`) rather than just a year.
struct DownloadedInfoMetadataRow: View {
    let item: DownloadedItem
    /// Computed once by the caller (`DownloadedAssetDetailView`) and passed
    /// in, rather than this view calling `DownloadFileStore
    /// .fileSize(forRelativePath:)` (a filesystem stat) itself — see that
    /// call site's own comment for why (`DownloadedDetailTabsView` needs
    /// the exact same number).
    let fileSizeBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let date = item.metadataDateText {
                    Text(date).accessibilityLabel(String(localized: "Released: \(date)"))
                }

                if let rating = item.metadata.officialRating {
                    Text(rating)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                        .accessibilityLabel(String(localized: "Age Rating: \(rating)"))
                }

                if let duration = item.durationText {
                    // "1h 32m" gets misheard by VoiceOver as "One H Thirty
                    // Two Meters" — see `DownloadedItem
                    // .durationAccessibilityText`'s doc comment.
                    Text(duration)
                        .accessibilityLabel(String(localized: "Duration: \(item.durationAccessibilityText ?? duration)"))
                }

                if let communityRating = item.metadata.communityRating {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                        Text(String(format: "%.1f", communityRating))
                    }
                    // See `InfoMetadataRow`'s identical treatment — one
                    // combined "Rated: 7.9 stars" instead of the star glyph
                    // and number reading as two separate VoiceOver stops.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        String(localized: "Rated: \(String(format: "%.1f", communityRating)) stars")
                    )
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !badges.isEmpty {
                Text(badges.joined(separator: " \u{00B7} "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        String(localized: "Formats: \(badges.map(Self.accessibilityBadge).joined(separator: ", "))")
                    )
            }
        }
    }

    /// Resolution, HDR (when applicable), whether subtitles are included,
    /// and the actual on-disk file size. Deliberately omits video codec —
    /// every download is transcoded to HEVC (see the offline-downloads
    /// plan), so showing it would just be the same word on every item.
    private var badges: [String] {
        var result: [String] = []
        if let resolution = Self.resolutionLabel(height: item.height) { result.append(resolution) }
        if item.isHDR { result.append("HDR") }
        if !item.subtitleFiles.isEmpty { result.append("CC") }
        if let fileSizeBytes {
            result.append(ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file))
        }
        return result
    }

    /// Coarse SD/HD/4K buckets — matches this page's original, simpler
    /// vocabulary rather than `MediaItem.metadataBadges`'s own "4K"/"HD"-
    /// only distinction stretched to a finer 1440p/1080p/720p/480p split;
    /// reverted per direct feedback that the finer buckets read as less
    /// user-friendly here.
    private static func resolutionLabel(height: Int?) -> String? {
        guard let height else { return nil }
        if height >= 2160 { return "4K" }
        if height >= 720 { return "HD" }
        return "SD"
    }

    /// See `InfoMetadataRow.accessibilityBadge(_:)` — identical copy, not
    /// shared, for the same reason that one documents. Only `CC` actually
    /// appears in this view's own `badges` (no DD/DD+ here — every download
    /// is transcoded to a fixed audio format), but kept as the same switch
    /// rather than a one-off special case in case that ever changes. The
    /// `default` case additionally spells out the file-size badge's unit
    /// (see `spokenFileSize(_:)`) — every other badge value falls through
    /// unchanged.
    fileprivate static func accessibilityBadge(_ badge: String) -> String {
        switch badge {
        case "CC": String(localized: "Closed Captions")
        case "DD+": String(localized: "Dolby Digital Plus")
        case "DD": String(localized: "Dolby Digital")
        default: spokenFileSize(badge)
        }
    }

    /// Visually "2.44 GB" (this view's own `badges` already formatted it via
    /// `ByteCountFormatter`), but VoiceOver reads that as "two dot
    /// forty-four G B" letter by letter rather than a real unit. Parses the
    /// already-formatted string rather than reimplementing
    /// `ByteCountFormatter`'s own unit-selection/rounding, so the two can
    /// never drift out of agreement. Returns `badge` unchanged for anything
    /// that isn't actually a byte-size string (resolution/HDR/CC all reach
    /// here too, via `accessibilityBadge`'s `default` case).
    private static func spokenFileSize(_ badge: String) -> String {
        guard let spaceIndex = badge.lastIndex(of: " ") else { return badge }
        let number = badge[..<spaceIndex]
        let unit = badge[badge.index(after: spaceIndex)...]
        let spokenUnit: String?
        switch unit {
        case "byte", "bytes": spokenUnit = String(localized: "bytes")
        case "KB": spokenUnit = String(localized: "kilobytes")
        case "MB": spokenUnit = String(localized: "megabytes")
        case "GB": spokenUnit = String(localized: "gigabytes")
        case "TB": spokenUnit = String(localized: "terabytes")
        case "PB": spokenUnit = String(localized: "petabytes")
        default: spokenUnit = nil
        }
        guard let spokenUnit else { return badge }
        return "\(number) \(spokenUnit)"
    }
}
