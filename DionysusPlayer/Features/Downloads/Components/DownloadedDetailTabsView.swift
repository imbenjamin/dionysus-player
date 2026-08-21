import SwiftUI

/// The offline counterpart to `DetailTabsView` — same segmented About/
/// Cast & Crew/Details structure, sourced from `DownloadedItem`/`.metadata`
/// instead of a live `MediaItem`. Reuses `MetadataLine`/`SummaryRow`/
/// `TrackListSection`/`CastCrewGridView` directly (all already
/// model-agnostic, or made so for this) rather than duplicating their
/// presentation.
struct DownloadedDetailTabsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case about = "About"
        case cast = "Cast & Crew"
        case details = "Details"
        var id: String { rawValue }
    }

    let item: DownloadedItem
    /// Computed once by the caller (`DownloadedAssetDetailView`) and
    /// threaded down to `DownloadedTechnicalDetailsView` — see that call
    /// site's own comment for why (`DownloadedInfoMetadataRow` needs the
    /// exact same number).
    let fileSizeBytes: Int64?
    @State private var selectedTab: Tab = .about

    /// `DownloadedPerson` has no id/headshot of its own (name/role only, to
    /// bound storage), and `imageURL` is always `nil`, which
    /// `CastCrewGridView` renders as a generic person glyph. `id` is
    /// synthesized from the person's name *and* position in the list, not
    /// the name alone — same fix as `MediaItem.cast`'s own `id`: the same
    /// person can appear as more than one credit (e.g. an actor who also
    /// directed), and a plain name-as-id gives `ForEach` duplicate ids for
    /// that case, causing intermittent gaps/repeated cells in the grid.
    private var castMembers: [CastMember] {
        item.metadata.people.enumerated().map { index, person in
            CastMember(id: "\(person.name)-\(index)", name: person.name, role: person.role, imageURL: nil)
        }
    }

    /// "About" always shows, same as the live page. "Cast & Crew" only
    /// once there's actually someone credited. "Details" always shows —
    /// unlike a live Show/Season/Collection, every `DownloadedItem` has its
    /// own media file (that's the whole point of a download), so there's
    /// no equivalent "nothing to show" case to hide it for.
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

/// Genres, then studios, then tagline, then synopsis — same order/styling
/// as `DetailTabsView`'s own `AboutTabContent`.
private struct DownloadedAboutTabContent: View {
    let item: DownloadedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !item.metadata.genres.isEmpty {
                MetadataLine(text: item.metadata.genres.joined(separator: " \u{00B7} "))
            }

            if !item.metadata.studios.isEmpty {
                MetadataLine(text: item.metadata.studios.joined(separator: " \u{00B7} "))
            }

            if let tagline = item.metadata.taglines.first, !tagline.isEmpty {
                Text(tagline)
                    .font(.title3.italic())
                    .foregroundStyle(.primary)
            }

            if let overview = item.metadata.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
            } else {
                Text("No synopsis available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The offline counterpart to `TechnicalDetailsView` — no version picker
/// (a download only ever has the one version that was actually fetched).
/// "Quality" is built from `item.bitrate` — the actually *achieved*
/// bitrate — rather than `displayName(in: item.requestedResolution)`,
/// which names the tier the user requested, not necessarily the one this
/// item was actually encoded at; those two can differ for a source
/// smaller than the requested tier (see `DownloadTranscodeCalculator
/// .target`'s doc comment). The skipped-subtitle-tracks list sits
/// alongside the rest of this item's technical specs, and — once there's
/// actually something skipped to contrast against — is split from the
/// downloaded list into its own "Downloaded"/"Not Available Offline" pair
/// (see `subtitleSections`'s own doc comment).
private struct DownloadedTechnicalDetailsView: View {
    let item: DownloadedItem
    let fileSizeBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                SummaryRow(label: "Container", value: "MP4")
                if let codec = item.videoCodec { SummaryRow(label: "Video Codec", value: codec.uppercased()) }
                if let resolution = resolutionText { SummaryRow(label: "Resolution", value: resolution) }
                SummaryRow(label: "Dynamic Range", value: item.isHDR ? "HDR10" : "SDR")
                SummaryRow(label: "Quality", value: qualityText)
                if let fileSize = fileSizeText { SummaryRow(label: "File Size", value: fileSize) }
            }

            TrackListSection(title: "Audio", tracks: [audioTrackSummary])

            subtitleSections
        }
    }

    /// One plain "Subtitles" list when every subtitle track made it into
    /// the download — the "Downloaded"/"Not Available Offline" split only
    /// earns its keep once there's actually something to contrast against,
    /// otherwise it's a redundant second header for the same list. Once
    /// something *was* skipped, both halves get the same
    /// `TrackListSection` list treatment for consistency.
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

    private var resolutionText: String? {
        guard let width = item.width, let height = item.height else { return nil }
        return "\(width)\u{00D7}\(height)"
    }

    /// e.g. "Normal (1.2 Mbps)" — same whole-number-vs-fractional Mbps
    /// formatting as `DownloadBitratePreset.displayName(in:)`, but from the
    /// real `item.bitrate` rather than recomputing one from
    /// `item.requestedResolution`; see this type's own doc comment for why
    /// that distinction matters. Falls back to the bare preset name with no
    /// parenthetical when `item.bitrate` is somehow missing (shouldn't
    /// happen in practice — always set at enqueue time).
    private var qualityText: String {
        guard let bitrate = item.bitrate, bitrate > 0 else { return item.requestedPreset.displayName }
        let mbps = Double(bitrate) / 1_000_000
        let mbpsText = mbps == mbps.rounded() ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps)
        return "\(item.requestedPreset.displayName) (\(mbpsText) Mbps)"
    }

    private var fileSizeText: String? {
        fileSizeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
    }

    /// Always AAC stereo audio (a deliberate v1 simplification) — entirely
    /// calculated from known facts about the transcode itself (channel
    /// layout, codec, the requested preset's own fixed audio bitrate),
    /// never from `item.selectedAudioTrackTitle`. That field is the
    /// *source* track's server-computed `displayTitle`, which bakes the
    /// source's original codec/channel layout into the string itself (e.g.
    /// "English (TrueHD 7.1)") — showing any part of it next to what was
    /// actually downloaded reads as a contradiction, so this drops the
    /// source title from the summary entirely rather than salvaging part
    /// of it.
    private var audioTrackSummary: String {
        let codec = (item.audioCodec ?? "aac").uppercased()
        let kbps = item.requestedPreset.audioBitrate / 1000
        return "\(String(localized: "Stereo")) \u{00B7} \(codec) \u{00B7} \(kbps) kbps"
    }
}
