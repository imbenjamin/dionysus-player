import SwiftUI

/// The "Details" tab's content: container/codec/resolution/dynamic-range
/// summary rows, then the full audio and subtitle track lists.
struct TechnicalDetailsView: View {
    let details: TechnicalDetails?

    var body: some View {
        if let details, !details.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
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
