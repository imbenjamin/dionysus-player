import SwiftUI

/// The "Details" tab's content: a version picker (only when `item` actually
/// has more than one — see `MediaItem.mediaVersions`), then that version's
/// container/codec/resolution/dynamic-range summary rows and full audio and
/// subtitle track lists.
struct TechnicalDetailsView: View {
    let item: MediaItem
    /// `nil` means "no explicit pick yet" — `selectedVersionID` binding
    /// below falls back to `mediaVersions.first`, not stored here directly,
    /// so a freshly-appeared version list (e.g. once `AssetDetailViewModel
    /// .load()` replaces the preloaded item) always has a valid selection
    /// without this view needing an `.onChange`/`.task` to seed one.
    @State private var selectedVersionID: String?

    private var versions: [MediaVersion] { item.mediaVersions }

    private var details: TechnicalDetails? {
        item.technicalDetails(forVersion: selectedVersionID)
    }

    /// Binding rather than reading/writing `selectedVersionID` directly in
    /// the `Picker` below — lets the control always show a real selection
    /// (defaulting to the first/highest-quality version) even before the
    /// user has ever touched it, while still only persisting an explicit
    /// choice to state.
    private var versionSelection: Binding<String> {
        Binding(
            get: { selectedVersionID ?? versions.first?.id ?? "" },
            set: { selectedVersionID = $0 }
        )
    }

    var body: some View {
        if let details, !details.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                if versions.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Version")
                            .font(.headline)
                        Picker("Version", selection: versionSelection) {
                            ForEach(versions) { version in
                                Text(version.label).tag(version.id)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(.dionysusPrimary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let container = details.container { SummaryRow(label: "Container", value: container) }
                    if let codec = details.videoCodec { SummaryRow(label: "Video Codec", value: codec) }
                    if let resolution = details.resolution { SummaryRow(label: "Resolution", value: resolution) }
                    if let dynamicRange = details.dynamicRange { SummaryRow(label: "Dynamic Range", value: dynamicRange) }
                    if let bitrate = details.bitrate { SummaryRow(label: "Bitrate", value: bitrate) }
                    if let fileSize = details.fileSize { SummaryRow(label: "File Size", value: fileSize) }
                }

                if !details.audioTracks.isEmpty {
                    TrackListSection(title: "Audio", tracks: details.audioTracks)
                }

                if !details.subtitleTracks.isEmpty {
                    TrackListSection(title: "Subtitles", tracks: details.subtitleTracks)
                }
            }
        } else {
            Text("No technical details available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct TrackListSection: View {
    let title: String
    let tracks: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                Text(track)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
