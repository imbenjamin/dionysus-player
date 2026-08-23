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
                if let date = item.metadataDateText { Text(date) }

                if let rating = item.metadata.officialRating {
                    Text(rating)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                }

                if let duration = item.durationText { Text(duration) }

                if let communityRating = item.metadata.communityRating {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                        Text(String(format: "%.1f", communityRating))
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !badges.isEmpty {
                Text(badges.joined(separator: " \u{00B7} "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
}
