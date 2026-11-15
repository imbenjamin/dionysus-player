import SwiftUI

/// A season download's question when its episodes' versions differ (#289):
/// one row per episode that has a choice, each with its own Version menu.
/// Episodes with one version aren't listed (D6) but still download, so the
/// Download button's spoken label counts every episode, not just the rows.
///
/// No row marks "(Last Played)", and a pick here isn't saved as the playback
/// preference (`MediaVersionPreferenceStore`): what suits a download (the
/// smaller file for a flight) says nothing about what to play at home
/// (Benjamin, 2026-11-14). The remembered pick only seeds each row.
///
/// A sheet rather than a dialog per episode: a season of differently cut
/// episodes would otherwise chain one question after another, with no way
/// to see or change an earlier answer.
struct BulkVersionChoiceSheet: View {
    let scans: [EpisodeScan]
    /// Every episode the download will queue, rows or not.
    let episodeCount: Int
    let onDownload: ([String: String]) -> Void
    let onCancel: () -> Void

    /// `MediaVersion.id` by episode id.
    @State private var picks: [String: String]

    /// `rememberedSourceID` answers an episode id with the version playback
    /// last chose for it: each row starts there, else on the server's
    /// default (the first), as the single download's sheet does.
    init(
        scans: [EpisodeScan], episodeCount: Int, rememberedSourceID: (String) -> String?,
        onDownload: @escaping ([String: String]) -> Void, onCancel: @escaping () -> Void
    ) {
        self.scans = scans
        self.episodeCount = episodeCount
        self.onDownload = onDownload
        self.onCancel = onCancel
        var picks: [String: String] = [:]
        for scan in scans {
            picks[scan.id] = DownloadVersionChoice.initialSheetSelection(
                versions: scan.versions, rememberedSourceID: rememberedSourceID(scan.id)
            )
        }
        _picks = State(initialValue: picks)
    }

    private func selection(for scan: EpisodeScan) -> Binding<String> {
        Binding(
            get: { picks[scan.id] ?? scan.versions.first?.id ?? "" },
            set: { picks[scan.id] = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(scans) { scan in
                        // `.menu`, not a push: the same choice as the single
                        // download's sheet, and a push loses taps to a
                        // sheet's own drag gesture there.
                        Picker(selection: selection(for: scan)) {
                            ForEach(scan.versions) { version in
                                // The server's own name for it, not localized.
                                Text(verbatim: version.label)
                                    .accessibilityIdentifier(A11yID.Versions.bulkRowOption(scan.id, version.id))
                                    .tag(version.id)
                            }
                        } label: {
                            Text(verbatim: scan.episode.numberedEpisodeName)
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier(A11yID.Versions.bulkRowPicker(scan.id))
                    }
                } footer: {
                    if episodeCount > scans.count {
                        Text("Episodes with only one version aren't listed.")
                    }
                }
            }
            .navigationTitle("Choose Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel, action: onCancel)
                        .toolbarTitleUnlessVertical()
                        .accessibilityIdentifier(A11yID.Versions.bulkCancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Just "Download" on screen: "Download 3 Episodes" took
                    // the bar's room and hid the sheet's title on iPhone
                    // (Benjamin, 2026-11-14). VoiceOver still hears the
                    // count, since the rows alone don't say that the
                    // unlisted single-version episodes download too.
                    Button("Download", systemImage: "arrow.down.circle") {
                        onDownload(picks)
                    }
                    .toolbarTitleUnlessVertical()
                    .accessibilityLabel(Text("Download \(episodeCount) Episodes"))
                    .accessibilityIdentifier(A11yID.Versions.bulkDownloadButton)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
