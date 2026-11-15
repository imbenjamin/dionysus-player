import Foundation

/// One of an item's media files (Jellyfin's "versions"): what the Details
/// tab's picker, the start-of-playback question and the download sheet all
/// list. `id` is the `MediaSourceInfo.id`; see `MediaItem.mediaVersions`.
struct MediaVersion: Identifiable, Hashable {
    let id: String
    let label: String
}

extension MediaVersion {
    /// Every media file backing an item when there is more than one. Often a
    /// technical variant (a 4K remux beside a 1080p encode), but just as often
    /// an edition with near-identical specs (a Director's Cut, an Extended
    /// Version). Empty when there is nothing to choose between: no media file
    /// at all, or the common single-version case.
    ///
    /// Ordered as the server returns `mediaSources`, which puts the version it
    /// would pick for direct play first, so the first entry is the default.
    ///
    /// Takes the raw sources rather than a `MediaItem` so a caller holding only
    /// a `PlaybackInfo` answer (the next episode, a download) labels versions
    /// exactly as the detail page does.
    static func versions(of sources: [MediaSourceInfo]) -> [MediaVersion] {
        guard sources.count > 1 else { return [] }
        // A filename-derived edition name (`editionLabel`) outranks the
        // resolution/dynamic-range bucket: it is what the uploader called this
        // version, which a technical bucket can't express and, for a same-spec
        // alternate cut, can't even distinguish from the original.
        let canonicalName = canonicalSourceName(sources)
        var seenLabels: Set<String> = []
        return sources.enumerated().map { index, source in
            var label: String
            if let canonicalName {
                // The naming convention identifies the base source but not what
                // dimension the others vary by, since the uploader chose those
                // names. A resolution or HDR guess here would imply a
                // convention that may not apply — an "Extended Version" beside
                // an identically-encoded original. "Original" is never wrong.
                label = editionLabel(for: source, canonicalName: canonicalName)
                    ?? String(localized: "Original")
            } else {
                label = versionLabel(for: source, fallbackIndex: index)
            }
            // Two versions can land on the same coarse label (two 1080p SDR
            // encodes), which would offer indistinguishable menu entries.
            if !seenLabels.insert(label).inserted {
                label += " (\(index + 1))"
            }
            return MediaVersion(id: source.id ?? String(index), label: label)
        }
    }

    /// The fallback label when `editionLabel` recovers no edition name: a
    /// coarse resolution and dynamic-range pair like "4K HDR10", using
    /// `metadataBadges`' buckets rather than `technicalDetails`' exact
    /// dimensions, since a picker entry must read at a glance. Falls back to the
    /// server's raw `MediaSourceInfo.name`, then to "Version N".
    private static func versionLabel(for source: MediaSourceInfo, fallbackIndex: Int) -> String {
        let videoStream = (source.mediaStreams ?? []).first { $0.type == "Video" }
        var parts: [String] = []
        if let width = videoStream?.width, let height = videoStream?.height,
           let commonName = MediaItem.resolutionCommonName(width: width, height: height) {
            parts.append(commonName)
        }
        if let dynamicRangeType = videoStream?.videoRangeType ?? videoStream?.videoRange,
           let badge = MediaItem.dynamicRangeBadge(dynamicRangeType) {
            parts.append(badge)
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if let name = source.name, !name.isEmpty { return name }
        return String(localized: "Version \(fallbackIndex + 1)")
    }

    /// The base filename every alternate version's `MediaSourceInfo.name`
    /// extends, per Jellyfin's multi-version naming convention: alternate cuts
    /// sit beside the primary file as `<primary file name> - <edition name>.ext`.
    /// `MediaSourceInfo.name` is the filename-derived stem, so the canonical
    /// source is whichever name is a literal prefix of every other's. `nil` when
    /// that doesn't hold, leaving callers to fall back to `versionLabel`.
    ///
    /// Not "split on ` - ` and take the last piece": filenames carry unrelated
    /// dashes of their own (`[Bluray-2160p]`, `x265]-GROUP`), so only a prefix
    /// comparison isolates the edition suffix reliably.
    private static func canonicalSourceName(_ sources: [MediaSourceInfo]) -> String? {
        let names = sources.map { $0.name ?? "" }
        guard sources.count > 1, names.allSatisfy({ !$0.isEmpty }) else { return nil }
        return names.first { candidate in
            names.allSatisfy { $0 == candidate || $0.hasPrefix(candidate + " - ") }
        }
    }

    /// The edition name encoded relative to `canonicalName` ("Extended
    /// Version", "Black and White"), verbatim as the uploader wrote it. `nil`
    /// for the canonical version, and when this name doesn't extend it.
    private static func editionLabel(for source: MediaSourceInfo, canonicalName: String?) -> String? {
        guard let canonicalName, let name = source.name, name != canonicalName else { return nil }
        let prefix = canonicalName + " - "
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = String(name.dropFirst(prefix.count))
        return suffix.isEmpty ? nil : suffix
    }
}
