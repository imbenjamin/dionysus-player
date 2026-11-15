import SwiftUI

/// A long-press on `DownloadButton` presents this instead of starting a
/// download immediately — lets the user override `DownloadPreferencesStore`'s
/// resolution/quality for *this one download only*, without touching the
/// device-wide default `ProfileView`'s Downloads section controls. Same
/// `Picker` shape/labels as that section (this should read as a per-item
/// extension of the same setting, not a different UI language), seeded
/// with the current preference so "just tap Download" reproduces the
/// normal one-tap behavior exactly.
///
/// With two or more versions it also asks which to download (#289, D9),
/// starting on the remembered playback pick, else the first; the sheet is
/// then the answer, and no version question follows it.
///
/// Purely a picker + confirm/cancel — it doesn't resolve audio tracks or
/// enqueue anything itself. `DownloadButton` runs its own existing
/// `startResolving()`/prompt/enqueue flow afterward, with the chosen
/// resolution/preset (and version) substituted for the defaults.
struct AdvancedDownloadOptionsView: View {
    let itemTitle: String
    /// The chosen resolution, preset and version. The version is `nil` for a
    /// title with only one, when there was nothing to pick.
    let onDownload: (DownloadResolution, DownloadBitratePreset, String?) -> Void

    /// The item's sources, every version, passed down from `DownloadButton`
    /// rather than fetched here (this sheet has no network access). Drives
    /// the Version picker (#289, D9), shown with two or more, and the size
    /// estimate, which reads the selected version's specs: the same fields
    /// `DownloadManager.enqueue` reads off the source it downloads. Empty
    /// just loses the estimate (`estimatedSizeText` returns `nil`).
    let sources: [MediaSourceInfo]
    var runtimeTicks: Int64? = nil

    @State private var resolution: DownloadResolution
    @State private var preset: DownloadBitratePreset
    /// The Version picker's selection, a `MediaVersion.id`; `nil` with no
    /// picker. Choosing here is the answer: no version question follows the
    /// sheet's Download.
    @State private var versionID: String?
    @Environment(\.dismiss) private var dismiss

    /// A fresh read on every access, not cached — cheap (one `UserDefaults`
    /// read), and picks up an override edited in Downloads → Advanced
    /// immediately if this sheet was already on screen underneath it.
    private var ladder: DownloadQualityLadderStore { DownloadQualityLadderStore() }

    /// `sources` as the picker lists them; empty with fewer than two.
    private var versions: [MediaVersion] { MediaVersion.versions(of: sources) }

    /// The selected version's source, or the only one.
    private var selectedSource: MediaSourceInfo? { DownloadVersionChoice.source(for: versionID, in: sources) }
    private var selectedVideoStream: MediaStream? { selectedSource?.mediaStreams?.first { $0.type == "Video" } }

    init(
        itemTitle: String, initialResolution: DownloadResolution, initialPreset: DownloadBitratePreset,
        sources: [MediaSourceInfo] = [], initialVersionID: String? = nil, runtimeTicks: Int64? = nil,
        onDownload: @escaping (DownloadResolution, DownloadBitratePreset, String?) -> Void
    ) {
        self.itemTitle = itemTitle
        self.sources = sources
        self.runtimeTicks = runtimeTicks
        self.onDownload = onDownload
        _resolution = State(initialValue: initialResolution)
        _preset = State(initialValue: initialPreset)
        _versionID = State(initialValue: initialVersionID)
    }

    /// Recomputed on every access, which is what makes it live: SwiftUI
    /// re-evaluates `body` whenever `resolution`/`preset` change (`@State`
    /// read right here), so this — and the `Text` displaying it — stay in
    /// sync with the pickers with no extra wiring. Routes through the same
    /// `DownloadTranscodeCalculator` capping logic the real download uses —
    /// but that logic computes the *bitrate ceiling* Jellyfin is allowed to
    /// spend, not what it actually will. Confirmed live (see DOWNLOADS.md's
    /// "Content-adaptive spread, in the wild"): the same server and
    /// settings landed anywhere from 46% to 93% of this figure depending on
    /// the title, and which end of that range a different reader's server
    /// lands on depends on their transcoder configuration (content-adaptive
    /// vs. CBR-like encoding) — undetectable from this app.
    /// `estimatedSizeText` presents this as an upper bound ("Up to …")
    /// rather than a point prediction; still worth showing, since the
    /// *ordering* between picker choices is always correct even when the
    /// absolute number isn't.
    private var estimatedTotalBytes: Int64? {
        DownloadTranscodeCalculator.estimatedTotalBytes(
            resolution: resolution, preset: preset, isSourceHDR: DownloadManager.isHDR(selectedVideoStream),
            sourceWidth: selectedVideoStream?.width, sourceHeight: selectedVideoStream?.height,
            // The video track's own bitrate first, as `DownloadManager.enqueue`
            // caps by.
            sourceBitrate: selectedVideoStream?.bitRate ?? selectedSource?.bitrate,
            sourceVideoCodec: selectedVideoStream?.codec, runtimeTicks: runtimeTicks,
            videoBitrateLadder: ladder.videoBitrate(resolution:preset:)
        )
    }

    private var estimatedSizeText: String? {
        estimatedTotalBytes.map { String(localized: "Up to \(FileSizeText.text(bytes: $0))") }
    }

    private var estimatedSizeAccessibilityText: String? {
        estimatedTotalBytes.map { String(localized: "Up to \(FileSizeText.accessibilityText(bytes: $0))") }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // First: which file comes before how it's encoded. `.menu`
                    // for the same reason as the two pickers below.
                    if versions.count > 1 {
                        Picker("Version", selection: $versionID) {
                            ForEach(versions) { version in
                                // The server's own name for it, not localized.
                                Text(verbatim: version.label)
                                    .accessibilityIdentifier(A11yID.AdvancedDownloadOptions.versionOption(version.id))
                                    .tag(Optional(version.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier(A11yID.AdvancedDownloadOptions.versionPicker)
                    }
                    // `.menu` style, not the default `List`-push style —
                    // the push loses a hit-testing fight against this
                    // sheet's own pan/resize gesture recognizer at a fixed
                    // `.medium` detent (taps registered a highlight but
                    // never completed). `.menu` sidesteps it by never
                    // pushing a destination.
                    Picker("Resolution", selection: $resolution) {
                        ForEach(DownloadResolution.allCases) { resolution in
                            Text(resolution.pickerDisplayName).tag(resolution)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(A11yID.AdvancedDownloadOptions.resolutionPicker)
                    Picker("Quality", selection: $preset) {
                        ForEach(DownloadBitratePreset.allCases) { preset in
                            Text(preset.displayName(bitrate: ladder.videoBitrate(resolution: resolution, preset: preset)))
                                .accessibilityIdentifier(A11yID.AdvancedDownloadOptions.qualityOption(preset.rawValue))
                                .tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(A11yID.AdvancedDownloadOptions.qualityPicker)
                    // Omitted entirely, not shown as "—", when there's
                    // nothing to estimate from — a dash reads as a loading
                    // state that never resolves, worse than no row at all.
                    if let estimatedSizeText {
                        SummaryRow(
                            label: String(localized: "Estimated Size"),
                            value: estimatedSizeText,
                            accessibilityValue: estimatedSizeAccessibilityText,
                            valueIdentifier: A11yID.AdvancedDownloadOptions.estimatedSize
                        )
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overrides your default download settings for this item only.")
                        if estimatedSizeText != nil {
                            Text("Actual size depends on your server's transcoder and the video itself — often smaller.")
                        }
                    }
                }
            }
            .navigationTitle(itemTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .toolbarTitleUnlessVertical()
                        .accessibilityIdentifier(A11yID.AdvancedDownloadOptions.cancelButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download", systemImage: "arrow.down.circle") {
                        onDownload(resolution, preset, versions.count > 1 ? versionID : nil)
                        dismiss()
                    }
                    .toolbarTitleUnlessVertical()
                    .accessibilityIdentifier(A11yID.AdvancedDownloadOptions.downloadButton)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
