import SwiftUI

/// Per-cell bitrate-ladder customization, pushed from `DownloadsSettingsView`
/// — lets a user override any of the twelve (4 resolutions × 3 quality
/// presets) entries in `DownloadResolution.videoBitrate(preset:)`'s shipped
/// table without touching the app's own tuned defaults (see `DOWNLOADS.md`).
/// Same "Advanced screen carved out of a parent settings screen" pattern as
/// `AdvancedPlaybackSettingsView` — reached only from `DownloadsSettingsView`,
/// via a plain `NavigationLink(destination:)` rather than a new `AppRoute`
/// case, for the same reasoning that view's own doc comment gives.
///
/// The user enters and sees **Kbps** here — a wide-enough unit that typing a
/// value feels precise (e.g. "3000" rather than "3") — while every other
/// picker in the app (`DownloadsSettingsView`'s own Quality picker,
/// `AdvancedDownloadOptionsView`'s per-item override sheet) keeps showing
/// Mbps, per the ask this screen was built for. `DownloadQualityLadderStore`
/// is the single source of truth for both the unit conversion and for what
/// "default" actually means; this view never hardcodes either.
///
/// Edits write straight through to `DownloadQualityLadderStore` on every
/// keystroke, mirroring the immediacy of every `@AppStorage`-backed control
/// elsewhere in Settings — there's no separate "Save" action. The store
/// itself isn't `@Observable` (it's a plain `UserDefaults` wrapper, same
/// shape as `DownloadPreferencesStore`), so `editedKbpsText` is this view's
/// own `@State` mirror of what's on disk: every action that writes to the
/// store also updates this dictionary in the same call, which is what
/// actually drives SwiftUI to re-render (and, e.g., re-evaluate
/// `hasAnyOverride` for the global reset button's enabled state) — reading
/// the store alone from `body` would show stale values until some unrelated
/// state change happened to trigger a re-render.
struct DownloadsQualityLadderView: View {
    private let store = DownloadQualityLadderStore()

    /// Mirrors what's actually committed to `store`, keyed the same way it
    /// keys its own storage internally. A missing entry means "show the
    /// store's current value" (itself falling through to the shipped
    /// default) — only `commitIfValid(_:for:)`/`reset(_:_:)`/`resetAll()`
    /// ever write to the store itself.
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

    /// Digit-filters `rawValue` (a `.numberPad` keyboard makes non-digit
    /// input rare, but this is the actual guarantee, not the keyboard type)
    /// and, only once it parses to a positive `Int`, writes it through to
    /// the store. An emptied or still-incomplete field updates the visible
    /// text but deliberately leaves the store untouched — snapping back to
    /// the default the instant a field is cleared would fight every
    /// keystroke of typing a shorter replacement value.
    ///
    /// The text shown afterward is the *clamped* value actually handed to
    /// `store.setOverride`, not the raw digits typed — a value past
    /// `DownloadQualityLadderStore.maxKbps` must visibly snap down to the
    /// ceiling rather than the field quietly disagreeing with what got
    /// saved underneath it.
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

    /// Writes the resolved default string back into `editedKbpsText` rather
    /// than clearing the entry to `nil` — a real bug, found live: `@State`
    /// skips a re-render when the newly assigned value is `Equatable`-equal
    /// to what's already there, and assigning `nil` to a dictionary key
    /// that was already absent (the common case — the field's displayed
    /// text came from `store.kbps(...)`'s own fallback the whole time, not
    /// from a prior edit in this dictionary) is exactly such a no-op: the
    /// store cleared correctly, but the on-screen field kept showing the
    /// stale overridden number until something unrelated forced a redraw.
    /// Writing the real post-reset value in guarantees the dictionary
    /// actually changes, so this always repaints immediately.
    private func reset(_ resolution: DownloadResolution, _ preset: DownloadBitratePreset) {
        store.setOverride(nil, resolution: resolution, preset: preset)
        editedKbpsText[cellKey(resolution, preset)] = String(store.kbps(resolution: resolution, preset: preset))
    }

    /// Same "assign the resolved value, not an empty placeholder" fix as
    /// `reset(_:_:)` above, for the same reason — resetting straight to
    /// `[:]` is a no-op `@State` silently skips whenever the dictionary
    /// already happened to be empty (e.g. every override so far was cleared
    /// via a per-row reset rather than typed by hand), leaving every field
    /// still showing its last stale number.
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
                    // The intro paragraph rides along in the *first*
                    // section's own header rather than a leading row/section
                    // of its own (tried both — a bare row, and a footer-only
                    // `Section`, each still carried the same reserved
                    // top-of-list margin an `.insetGrouped` `List` gives its
                    // first section regardless of whether that section has a
                    // real header, leaving a blank gap no row-level modifier
                    // could cancel; pulling it fully outside the `List` into
                    // a separate `VStack` closed that gap but stopped it
                    // scrolling away with the rest of the page, which is
                    // wrong the other direction). A real section header is
                    // the one place already confirmed to render with correct
                    // spacing — "4K UHD" alone always has — so stacking the
                    // intro above it here inherits that for free, and it
                    // still scrolls normally since it's genuine `List`
                    // content, not something pinned outside it.
                    if resolution == DownloadResolution.allCases.first {
                        VStack(alignment: .leading, spacing: 8) {
                            // `.primary`, not `.secondary` — this is
                            // multi-sentence body copy the user needs to
                            // actually read, not an auxiliary caption, and
                            // stacking `.secondary`'s own dimming on top of
                            // a `List` header's already-muted ambient
                            // styling made it noticeably harder to read
                            // than the same style reads anywhere else in
                            // the app.
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
            // A toolbar item, not a row at the bottom of the list — this is
            // a whole-page action (every resolution/quality cell, not just
            // whichever section happens to be on screen), so it stays
            // reachable without scrolling past all four resolution sections
            // to find it, the same way a "whole-page" reset action reads in
            // iOS Settings itself.
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
                // `.accessibilityLabel` here (not wrapping the whole `HStack`
                // in `.accessibilityElement(children: .ignore)`) deliberately
                // keeps the `TextField` itself as the accessible element —
                // VoiceOver reads its bound text as the value and can still
                // double-tap to edit it; collapsing it into one ignored
                // group the way a Button's label content sometimes is
                // (see `AdvancedDownloadOptionsView`'s own accessibility
                // notes) would silently remove that editing affordance.
                TextField("Kbps", text: text(for: resolution, preset))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .accessibilityLabel(Text("\(preset.displayName) bitrate, in kilobits per second"))
                // Purely a decorative unit suffix next to the field above —
                // hidden rather than read as a second, redundant element.
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
