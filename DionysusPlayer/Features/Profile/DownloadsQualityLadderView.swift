import SwiftUI

/// Per-cell bitrate-ladder customization, pushed from `DownloadsSettingsView`:
/// lets a user override any of the twelve (4 resolutions × 3 quality presets)
/// entries in `DownloadResolution.videoBitrate(preset:)`'s shipped table without
/// touching the tuned defaults (see `DOWNLOADS.md`). Same carved-out Advanced
/// screen pattern as `AdvancedPlaybackSettingsView`, reached via a plain
/// `NavigationLink(destination:)` rather than a new `AppRoute` case.
///
/// Values here are in Kbps, a wide enough unit that typing one feels precise
/// ("3000" rather than "3"), while every other picker in the app shows Mbps.
/// `DownloadQualityLadderStore` owns both the unit conversion and what "default"
/// means; this view hardcodes neither.
///
/// Edits write straight through to the store on every keystroke, with no separate
/// Save, matching every `@AppStorage`-backed control in Settings. The store isn't
/// `@Observable` — a plain `UserDefaults` wrapper like `DownloadPreferencesStore`
/// — so `editedKbpsText` is this view's `@State` mirror of what's on disk: every
/// write to the store updates it in the same call, which is what drives the
/// re-render (including re-evaluating `hasAnyOverride` for the global reset
/// button). Reading the store from `body` alone would show stale values until
/// something unrelated forced a redraw.
struct DownloadsQualityLadderView: View {
    private let store = DownloadQualityLadderStore()

    /// Mirrors what's committed to `store`, keyed the way it keys its own storage.
    /// A missing entry means "show the store's current value", itself falling
    /// through to the shipped default. Only
    /// `commitIfValid(_:for:)`/`reset(_:_:)`/`resetAll()` write to the store.
    @State private var editedKbpsText: [String: String] = [:]
    @State private var isConfirmingResetAll = false

    private func cellKey(_ resolution: DownloadResolution, _ preset: DownloadBitratePreset) -> String {
        "\(resolution.rawValue).\(preset.rawValue)"
    }

    private func text(for resolution: DownloadResolution, _ preset: DownloadBitratePreset) -> Binding<String> {
        Binding(
            get: {
                editedKbpsText[cellKey(resolution, preset)]
                    ?? String(store.kbps(resolution: resolution, preset: preset))
            },
            set: { commitIfValid($0, resolution: resolution, preset: preset) }
        )
    }

    /// Digit-filters `rawValue` — the keyboard type is `.numberPad`, but this is
    /// the guarantee — and writes through to the store only once it parses to a
    /// positive `Int`. An emptied or incomplete field updates the visible text but
    /// leaves the store alone: snapping back to the default the instant a field is
    /// cleared would fight every keystroke of typing a shorter value.
    ///
    /// The text shown afterwards is the clamped value handed to
    /// `store.setOverride`, not the raw digits, so a value past
    /// `DownloadQualityLadderStore.maxKbps` visibly snaps to the ceiling rather
    /// than disagreeing with what was saved.
    private func commitIfValid(_ rawValue: String, resolution: DownloadResolution, preset: DownloadBitratePreset) {
        let digitsOnly = rawValue.filter(\.isNumber)
        guard let kbps = Int(digitsOnly), kbps > 0 else {
            editedKbpsText[cellKey(resolution, preset)] = digitsOnly
            return
        }
        let clamped = min(max(kbps, DownloadQualityLadderStore.minKbps), DownloadQualityLadderStore.maxKbps)
        store.setOverride(clamped, resolution: resolution, preset: preset)
        editedKbpsText[cellKey(resolution, preset)] = String(clamped)
    }

    /// Writes the resolved default string into `editedKbpsText` rather than
    /// clearing the entry to `nil`. `@State` skips a re-render when the assigned
    /// value is `Equatable`-equal to what's there, and assigning `nil` to an
    /// already-absent key is exactly that — the common case, since the field's
    /// text came from `store.kbps(...)`'s fallback rather than a prior edit. The
    /// store cleared correctly while the field kept showing the stale number.
    private func reset(_ resolution: DownloadResolution, _ preset: DownloadBitratePreset) {
        store.setOverride(nil, resolution: resolution, preset: preset)
        editedKbpsText[cellKey(resolution, preset)] = String(store.kbps(resolution: resolution, preset: preset))
    }

    /// Same fix as `reset(_:_:)`: assigning `[:]` is a no-op `@State` skips
    /// whenever the dictionary is already empty, leaving every field showing its
    /// stale number.
    private func resetAll() {
        store.resetAll()
        editedKbpsText = Dictionary(
            uniqueKeysWithValues: DownloadResolution.allCases.flatMap { resolution in
                DownloadBitratePreset.allCases.map { preset in
                    (cellKey(resolution, preset), String(store.kbps(resolution: resolution, preset: preset)))
                }
            }
        )
    }

    var body: some View {
        List {
            ForEach(DownloadResolution.allCases) { resolution in
                Section {
                    ForEach(DownloadBitratePreset.allCases) { preset in
                        row(resolution: resolution, preset: preset)
                    }
                } header: {
                    // The intro paragraph rides in the first section's header
                    // rather than a leading row or section of its own. A bare row
                    // and a footer-only `Section` both carried the reserved
                    // top-of-list margin an `.insetGrouped` `List` gives its first
                    // section, leaving a gap no row-level modifier could cancel;
                    // a separate `VStack` outside the `List` closed the gap but
                    // stopped it scrolling. A real section header renders with
                    // correct spacing, and this is still genuine `List` content.
                    if resolution == DownloadResolution.allCases.first {
                        VStack(alignment: .leading, spacing: 8) {
                            // `.primary`, not `.secondary`: this is body copy to
                            // read, not a caption, and `.secondary`'s dimming on
                            // top of a `List` header's already-muted styling made
                            // it harder to read than the same style elsewhere.
                            Text("Fine-tune the video bitrate the app requests for each resolution and quality level, in kilobits per second (Kbps). Everywhere else in the app continues to show the equivalent value in megabits per second (Mbps).\n\nDefaults assume a software-encoded HEVC transcode and may not be optimal for your own server's transcoder configuration.")
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .textCase(nil)
                            Text(resolution.displayName)
                        }
                    } else {
                        Text(resolution.displayName)
                    }
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A toolbar item, not a row at the list's bottom: this resets every
            // resolution/quality cell, not the section on screen, so it stays
            // reachable without scrolling past all four sections — as a whole-page
            // reset reads in iOS Settings.
            ToolbarItem(placement: .primaryAction) {
                Button("Reset All", role: .destructive) {
                    isConfirmingResetAll = true
                }
                .disabled(!store.hasAnyOverride)
            }
        }
        .confirmationDialog(
            "Reset All to Defaults?",
            isPresented: $isConfirmingResetAll,
            titleVisibility: .visible
        ) {
            Button("Reset All to Defaults", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears every custom bitrate you've set above. It can't be undone.")
        }
    }

    private func row(resolution: DownloadResolution, preset: DownloadBitratePreset) -> some View {
        let defaultKbps = resolution.videoBitrate(preset: preset) / 1000
        let isOverridden = store.isOverridden(resolution: resolution, preset: preset)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName)
                Text("Default: \(defaultKbps) Kbps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                // `.accessibilityLabel` rather than wrapping the `HStack` in
                // `.accessibilityElement(children: .ignore)`, which keeps the
                // `TextField` as the accessible element: VoiceOver reads its bound
                // text as the value and can double-tap to edit. Collapsing it into
                // one ignored group would remove that affordance.
                TextField("Kbps", text: text(for: resolution, preset))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .accessibilityLabel(Text("\(preset.displayName) bitrate, in kilobits per second"))
                // A decorative unit suffix, hidden rather than read as a second
                // element.
                Text("Kbps")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if isOverridden {
                Button {
                    reset(resolution, preset)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Reset \(preset.displayName) to Default"))
            }
        }
    }
}

#Preview {
    NavigationStack { DownloadsQualityLadderView() }
}
