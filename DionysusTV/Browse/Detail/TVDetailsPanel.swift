import SwiftUI

/// The Details panel at the foot of a detail page: a summary of what the
/// item says about itself; Select opens the full list (`TVFullDetailsView`).
/// Draws nothing for an item with nothing to say.
struct TVDetailsPanel: View {
    let item: MediaItem
    /// Named beside the heading when the details aren't the page's own
    /// item's: on a show's page, which episode they describe.
    var subject: String?
    /// The version the summary describes when the title has several (#289):
    /// the remembered pick, which Play would start; `nil` (or a version the
    /// title no longer has) describes the first. Full Details opens on it.
    var versionID: String?
    let focus: FocusState<String?>.Binding
    @State private var showsFullDetails = false

    static let focusID = "details"

    static func hasRows(for item: MediaItem) -> Bool { !rows(for: item).isEmpty }

    /// The technical rows are there only once the full item, with its media
    /// source, has loaded; a show has none at all. A title with several
    /// versions names them all ("4K HDR10, 1080p"; D10), since the summary
    /// describes only one and Full Details is where the others are.
    static func rows(for item: MediaItem, versionID: String? = nil) -> [(label: String, value: String)] {
        let details = item.technicalDetails(forVersion: versionID)
        let versions = item.mediaVersions
        let video = [details?.resolution, details?.dynamicRange].compactMap { $0 }.joined(separator: " · ")
        let rows: [(String, String?)] = [
            (String(localized: "Studio"), item.studios.first),
            (String(localized: "Released"), item.metadataDateText),
            (String(localized: "Genres"), item.genres.isEmpty ? nil : item.genres.joined(separator: ", ")),
            (String(localized: "Rating"), item.ageRating),
            (String(localized: "Versions"), versions.count > 1 ? versions.map(\.label).joined(separator: ", ") : nil),
            (String(localized: "Video"), video),
            (String(localized: "Audio"), details?.audioTracks.first),
            (String(localized: "Subtitles"), (details?.subtitleTracks.isEmpty ?? true) ? nil : details?.subtitleTracks.joined(separator: ", ")),
            (String(localized: "Runtime"), item.durationText)
        ]
        return rows.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }

    var body: some View {
        let rows = Self.rows(for: item, versionID: versionID)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Details").font(.headline).accessibilityAddTraits(.isHeader)
                    if let subject {
                        Text(verbatim: subject)
                            .font(.callout).foregroundStyle(.secondary)
                            .accessibilityIdentifier(A11yID.TV.Detail.detailsSubject)
                    }
                }
                Button { showsFullDetails = true } label: {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 4), alignment: .leading, spacing: 30) {
                        ForEach(rows, id: \.label) { label, value in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: label.uppercased()).font(.caption2).foregroundStyle(.secondary)
                                Text(verbatim: value).lineLimit(2).multilineTextAlignment(.leading)
                            }
                        }
                    }
                    .padding(30)
                    .background(.white.opacity(focus.wrappedValue == Self.focusID ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)
                .focused(focus, equals: Self.focusID)
                .accessibilityLabel(String(localized: "Details"))
                .accessibilityHint(String(localized: "Shows every detail and track"))
                .accessibilityIdentifier(A11yID.TV.Detail.details)
            }
            .padding(.trailing, 80)
            .fullScreenCover(isPresented: $showsFullDetails) {
                TVFullDetailsView(item: item, initialVersionID: versionID)
            }
        }
    }
}
