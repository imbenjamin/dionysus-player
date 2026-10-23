import SwiftUI

/// About Spatial Audio, opened from the Spatial Audio section's Learn More
/// button so the section's footer can stay one sentence (Benjamin,
/// 2026-10-23). The text is `SpatialAudioHelp`, shared with the Apple TV's
/// About Spatial Audio page.
struct SpatialAudioHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(SpatialAudioHelp.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                    }
                }
                .frame(maxWidth: SettingsLayout.readableFooterWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                // On the text block, never the sheet's root: an identifier
                // there can overwrite every descendant's own (`A11yID`).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(A11yID.Profile.spatialAudioHelp)
            }
            .navigationTitle("About Spatial Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(A11yID.Profile.spatialAudioHelpDone)
                }
            }
        }
        .presentationDetents([.large])
    }
}
