import SwiftUI

/// The offline counterpart to `DetailTabsView`: the same segmented About/Cast &
/// Crew/Details structure, sourced from `DownloadedItem`/`.metadata` rather than a
/// live `MediaItem`. Reuses
/// `MetadataLine`/`SummaryRow`/`TrackListSection`/`CastCrewGridView` directly.
struct DownloadedDetailTabsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case about = "About"
        case cast = "Cast & Crew"
        case details = "Details"
        var id: String { rawValue }
    }

    let item: DownloadedItem
    /// Computed once by `DownloadedAssetDetailView` and threaded down to
    /// `DownloadedTechnicalDetailsView`, since `DownloadedInfoMetadataRow` needs
    /// the same number.
    let fileSizeBytes: Int64?
    @State private var selectedTab: Tab = .about

    /// `DownloadedPerson` stores name and role only, to bound storage, so
    /// `imageURL` is always `nil` and `CastCrewGridView` renders a generic person
    /// glyph. `id` is synthesized from the name and the position in the list, not
    /// the name alone — the same fix as `MediaItem.cast`'s `id`: one person can
    /// hold several credits, and a name-as-id gives `ForEach` duplicate ids,
    /// causing intermittent gaps and repeated cells.
    private var castMembers: [CastMember] {
        item.metadata.people.enumerated().map { index, person in
            CastMember(id: "\(person.name)-\(index)", name: person.name, role: person.role, imageURL: nil)
        }
    }

    /// "About" always shows, as on the live page; "Cast & Crew" only with someone
    /// credited; "Details" always, since every `DownloadedItem` has a media file,
    /// unlike a live Show/Season/Collection.
    private var availableTabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .about: true
            case .cast: !castMembers.isEmpty
            case .details: true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if availableTabs.count > 1 {
                Picker("Section", selection: $selectedTab) {
                    ForEach(availableTabs) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.dionysusPrimary)
            }

            switch selectedTab {
            case .about:
                DownloadedAboutTabContent(item: item)
            case .cast:
                CastCrewGridView(cast: castMembers)
            case .details:
                DownloadedTechnicalDetailsView(item: item, fileSizeBytes: fileSizeBytes)
            }
        }
    }
}

/// Genres, studios, tagline, synopsis — the order and styling of
/// `DetailTabsView`'s `AboutTabContent`.
private struct DownloadedAboutTabContent: View {
    let item: DownloadedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !item.metadata.genres.isEmpty {
                MetadataLine(items: item.metadata.genres, accessibilityPrefix: String(localized: "Genres"))
            }

            if !item.metadata.studios.isEmpty {
                MetadataLine(items: item.metadata.studios, accessibilityPrefix: String(localized: "Studios"))
            }

            if let tagline = item.metadata.taglines.first, !tagline.isEmpty {
                Text(tagline)
                    .font(.title3.italic())
                    .foregroundStyle(.primary)
                    .accessibilityLabel(String(localized: "Tagline: \(tagline)"))
            }

            if let overview = item.metadata.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .accessibilityLabel(String(localized: "Synopsis: \(overview)"))
            } else {
                Text("No synopsis available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Synopsis: No synopsis available."))
            }
        }
    }
}

/// The offline counterpart to `TechnicalDetailsView`, with no version picker: a
/// download has only the version that was fetched.
///
/// "Quality" comes from `item.bitrate`, the achieved bitrate, rather than
/// `displayName(in: item.requestedResolution)`, which names the requested tier.
/// The two differ for a source smaller than that tier — see
/// `DownloadTranscodeCalculator.target`.
///
/// Skipped subtitle tracks sit alongside the rest of the technical specs, split
/// from the downloaded list into a "Downloaded"/"Not Available Offline" pair once
/// something was actually skipped (see `subtitleSections`).
private struct DownloadedTechnicalDetailsView: View {
    let item: DownloadedItem
    let fileSizeBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                if let resolution = resolutionText { SummaryRow(label: "Resolution", value: resolution) }
                SummaryRow(label: "Dynamic Range", value: item.isHDR ? "HDR10" : "SDR")
                SummaryRow(label: "Quality", value: qualityText, accessibilityValue: qualityAccessibilityText)
                if let fileSize = fileSizeText {
                    SummaryRow(label: "File Size", value: fileSize, accessibilityValue: fileSizeAccessibilityText)
                }
            }

            TrackListSection(title: "Audio", tracks: [audioTrackSummary])

            subtitleSections
        }
    }

    /// One plain "Subtitles" list when every track made it into the download: the
    /// "Downloaded"/"Not Available Offline" split is a redundant second header
    /// with nothing to contrast against. Once something was skipped, both halves
    /// get the same `TrackListSection` treatment.
    @ViewBuilder
    private var subtitleSections: some View {
        if item.skippedSubtitleTracks.isEmpty {
            if !item.subtitleFiles.isEmpty {
                TrackListSection(title: "Subtitles", tracks: item.subtitleFiles.map(\.displayTitle))
            }
        } else {
            if !item.subtitleFiles.isEmpty {
                TrackListSection(title: "Downloaded", tracks: item.subtitleFiles.map(\.displayTitle))
            }
            VStack(alignment: .leading, spacing: 4) {
                TrackListSection(title: "Not Available Offline", tracks: item.skippedSubtitleTracks)
                Text("Image-based subtitle tracks can't be included in offline downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The live Details tab's "dimensions (common name)" formatting, e.g.
    /// "1920×1080 (1080p)", shared from `MediaItem.resolutionLabel` so the two
    /// pages can't describe the same resolution differently.
    private var resolutionText: String? {
        guard let width = item.width, let height = item.height else { return nil }
        return MediaItem.resolutionLabel(width: width, height: height)
    }

    /// "Normal (1.2 Mbps)": the whole-number-versus-fractional Mbps formatting of
    /// `DownloadBitratePreset.displayName(in:)`, but from the real `item.bitrate`
    /// rather than recomputed from `item.requestedResolution` — see this type's doc
    /// comment. Falls back to the bare preset name when `item.bitrate` is missing,
    /// which shouldn't happen since it's set at enqueue time.
    private var qualityText: String {
        guard let bitrate = item.bitrate, bitrate > 0 else { return item.requestedPreset.displayName }
        let mbps = Double(bitrate) / 1_000_000
        let mbpsText = mbps == mbps.rounded() ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps)
        return "\(item.requestedPreset.displayName) (\(mbpsText) Mbps)"
    }

    /// `qualityText`'s VoiceOver counterpart, with "Mbps" read letter by letter.
    /// Same number formatting, so the two differ only in the unit's spelling.
    private var qualityAccessibilityText: String {
        guard let bitrate = item.bitrate, bitrate > 0 else { return item.requestedPreset.displayName }
        let mbps = Double(bitrate) / 1_000_000
        let mbpsText = mbps == mbps.rounded() ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps)
        return "\(item.requestedPreset.displayName) (\(mbpsText) megabits per second)"
    }

    private var fileSizeText: String? {
        fileSizeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
    }

    /// `fileSizeText`'s VoiceOver counterpart; see
    /// `DownloadedInfoMetadataRow.spokenFileSize(_:)`, which parses
    /// `ByteCountFormatter`'s output rather than reimplementing its rounding.
    private var fileSizeAccessibilityText: String? {
        guard let fileSizeText else { return nil }
        guard let spaceIndex = fileSizeText.lastIndex(of: " ") else { return fileSizeText }
        let number = fileSizeText[..<spaceIndex]
        let unit = fileSizeText[fileSizeText.index(after: spaceIndex)...]
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
        guard let spokenUnit else { return fileSizeText }
        return "\(number) \(spokenUnit)"
    }

    /// Always AAC stereo, a v1 simplification, and derived entirely from known
    /// facts about the transcode — channel layout, codec, the preset's fixed audio
    /// bitrate — never from `item.selectedAudioTrackTitle`. That field is the
    /// source track's server-computed `displayTitle`, which bakes the source's
    /// codec and layout into the string ("English (TrueHD 7.1)"), and showing any
    /// of it next to what was downloaded reads as a contradiction.
    private var audioTrackSummary: String {
        let codec = (item.audioCodec ?? "aac").uppercased()
        let kbps = item.requestedPreset.audioBitrate / 1000
        return "\(String(localized: "Stereo")) \u{00B7} \(codec) \u{00B7} \(kbps) kbps"
    }
}
