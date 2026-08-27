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

    @State private var resolution: DownloadResolution
    @State private var preset: DownloadBitratePreset
    @Environment(\.dismiss) private var dismiss

    init(itemTitle: String, initialResolution: DownloadResolution, initialPreset: DownloadBitratePreset, onDownload: @escaping (DownloadResolution, DownloadBitratePreset) -> Void) {
        self.itemTitle = itemTitle
        self.onDownload = onDownload
        _resolution = State(initialValue: initialResolution)
        _preset = State(initialValue: initialPreset)
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
                } footer: {
                    Text("Overrides your default download settings for this item only.")
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
