import SwiftUI

/// The offline counterpart to `InfoMetadataRow` — same two-line
/// composition (year/rating/duration/community-rating, then a
/// dot-separated badges line), sourced from `DownloadedItem`/`.metadata`
/// rather than a live `MediaItem`. Badges differ slightly from the live
/// page's own `MediaItem.metadataBadges`: no audio-format/accessibility
/// badges (nothing here varies per download the way it does live — see
/// the old `DownloadedAssetDetailView.metadataLine`'s doc comment this
/// replaces), but adds the actual on-disk file size, which only makes
/// sense for a download.
struct DownloadedInfoMetadataRow: View {
    let item: DownloadedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let year = item.metadata.productionYear { Text(String(year)) }

                if let rating = item.metadata.officialRating {
                    Text(rating)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                }

                if let duration = Self.durationText(ticks: item.runtimeTicks) { Text(duration) }

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
        if let fileSize = DownloadFileStore.fileSize(forRelativePath: item.videoFilePath) {
            result.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
        }
        return result
    }

    /// Same "Xh Ym" formatting as `MediaItem.durationText` — duplicated
    /// rather than shared since that one is `private` on a type built
    /// around a live `BaseItemDto`, and this only needs the one line of
    /// tick math.
    private static func durationText(ticks: Int64?) -> String? {
        guard let ticks, ticks > 0 else { return nil }
        let totalMinutes = Int(ticks / 10_000_000 / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
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
