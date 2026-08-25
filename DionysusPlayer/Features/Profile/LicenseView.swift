import SwiftUI

/// Displays the app's license text, bundled from the repo's own `LICENSE`
/// file (`DionysusPlayer/Resources/LICENSE` is a symlink to it, not a
/// copy — see `project.yml`'s `buildPhase: resources` override for why an
/// explicit entry was needed) so there's a single source of truth: editing
/// the real `LICENSE` updates what this screen shows with no separate sync
/// step.
///
/// Reached only from `ProfileView`, via a plain `NavigationLink(destination:)`
/// rather than a new `AppRoute` case — same reasoning as
/// `DownloadsSettingsView`.
struct LicenseView: View {
    /// Loaded once per screen presentation, not cached — this is a rarely
    /// visited screen reading a small bundled text file, not worth an
    /// `@Observable` loader for.
    private var licenseText: String {
        guard
            let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            // Should only happen if the bundled resource is ever missing —
            // not a user-facing error state worth a LoadState enum for.
            return String(localized: "License text unavailable.")
        }
        return text
    }

    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("License")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        LicenseView()
    }
}
#endif
