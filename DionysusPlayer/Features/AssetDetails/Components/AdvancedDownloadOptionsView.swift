import SwiftUI

/// A long-press on `DownloadButton` presents this instead of starting a
/// download immediately — lets the user override `DownloadPreferencesStore`'s
/// resolution/quality for *this one download only*, without touching the
/// device-wide default `ProfileView`'s Downloads section controls. Same
/// `Picker` shape/labels as that section (deliberately — this should read as
/// a per-item extension of the same setting, not a different UI language),
/// seeded with the current preference as its starting selection so "just
/// tap Download" here reproduces the normal one-tap behavior exactly.
///
/// Purely a picker + confirm/cancel — it doesn't itself know how to resolve
/// audio tracks or enqueue anything. `DownloadButton` runs its own existing
/// `startResolving()`/prompt/enqueue flow afterward, just with the chosen
/// resolution/preset substituted in place of `DownloadPreferencesStore`'s.
struct AdvancedDownloadOptionsView: View {
    let itemTitle: String
    let onDownload: (DownloadResolution, DownloadBitratePreset) -> Void

    /// Raw source specs `DownloadTranscodeCalculator.estimatedTotalBytes`
    /// needs — the same fields `DownloadManager.enqueue` reads off the
    /// item's own `mediaSources`, passed down from `DownloadButton` rather
    /// than fetched here (this sheet has no network access of its own, and
    /// none is needed: a detail page's `MediaItem` already carries this from
    /// its own load). All independently optional/defaulted so an item
    /// missing some piece of metadata just quietly loses the estimate
    /// (`estimatedSizeText` returns `nil`) rather than this view needing a
    /// non-optional contract it can't always satisfy.
    var sourceWidth: Int? = nil
    var sourceHeight: Int? = nil
    var sourceBitrate: Int? = nil
    var isSourceHDR: Bool = false
    var sourceVideoCodec: String? = nil
    var runtimeTicks: Int64? = nil

    @State private var resolution: DownloadResolution
    @State private var preset: DownloadBitratePreset
    @Environment(\.dismiss) private var dismiss

    init(
        itemTitle: String, initialResolution: DownloadResolution, initialPreset: DownloadBitratePreset,
        sourceWidth: Int? = nil, sourceHeight: Int? = nil, sourceBitrate: Int? = nil,
        isSourceHDR: Bool = false, sourceVideoCodec: String? = nil, runtimeTicks: Int64? = nil,
        onDownload: @escaping (DownloadResolution, DownloadBitratePreset) -> Void
    ) {
        self.itemTitle = itemTitle
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceBitrate = sourceBitrate
        self.isSourceHDR = isSourceHDR
        self.sourceVideoCodec = sourceVideoCodec
        self.runtimeTicks = runtimeTicks
        self.onDownload = onDownload
        _resolution = State(initialValue: initialResolution)
        _preset = State(initialValue: initialPreset)
    }

    /// Recomputed on every access, which is what makes it live: SwiftUI
    /// re-evaluates `body` whenever `resolution`/`preset` change (they're
    /// `@State` read right here), so this — and the `Text` displaying it —
    /// stay in sync with the pickers above with no extra wiring. Routes
    /// through the same `DownloadTranscodeCalculator` capping logic the real
    /// download will use — but that logic computes the *bitrate ceiling*
    /// Jellyfin is allowed to spend, not what it actually will. Confirmed
    /// live (2026-08-27, see DOWNLOADS.md's "Content-adaptive spread, in the
    /// wild"): the same server, same settings, landed anywhere from 46% to
    /// 93% of this figure depending on the title, and which end of that
    /// range a *different* reader's server lands on depends on their own
    /// transcoder configuration (content-adaptive CRF software encoding vs.
    /// CBR-like hardware encoding) — something this app has no way to
    /// detect. `estimatedSizeText` presents this honestly as an upper bound
    /// ("Up to …") rather than a point prediction; still worth showing,
    /// since the *ordering* between picker choices is always correct even
    /// when the absolute number isn't.
    private var estimatedTotalBytes: Int64? {
        DownloadTranscodeCalculator.estimatedTotalBytes(
            resolution: resolution, preset: preset, isSourceHDR: isSourceHDR,
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, sourceBitrate: sourceBitrate,
            sourceVideoCodec: sourceVideoCodec, runtimeTicks: runtimeTicks
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
                    // `.menu` style, not the default `List`-push style —
                    // the default style's `NavigationLink`-shaped push
                    // reliably loses a hit-testing fight against this
                    // sheet's own pan/resize gesture recognizer at a fixed
                    // `.medium` detent (most taps registered a highlight
                    // but never completed the push). `.menu` sidesteps the
                    // conflict by never pushing a destination at all.
                    Picker("Resolution", selection: $resolution) {
                        ForEach(DownloadResolution.allCases) { resolution in
                            Text(resolution.pickerDisplayName).tag(resolution)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Quality", selection: $preset) {
                        ForEach(DownloadBitratePreset.allCases) { preset in
                            Text(preset.displayName(in: resolution)).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    // Omitted entirely, not shown as "—", when there's
                    // nothing to estimate from (see `estimatedTotalBytes`'s
                    // own doc comment) — a dash reads as a loading state
                    // that's never going to resolve, which is worse than no
                    // row at all.
                    if let estimatedSizeText {
                        SummaryRow(
                            label: String(localized: "Estimated Size"),
                            value: estimatedSizeText,
                            accessibilityValue: estimatedSizeAccessibilityText
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
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        onDownload(resolution, preset)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
