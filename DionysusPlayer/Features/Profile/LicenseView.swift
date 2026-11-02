import SwiftUI

/// Displays the app's license text, then each bundled library's notices
/// under a small heading with its name (`LicenseDocument`), so it's clear
/// which component a license refers to. Both come from the repo's own
/// `LICENSE` and `THIRD-PARTY-NOTICES` files (symlinks in
/// `DionysusPlayer/Resources/`, not copies — see `project.yml`'s
/// `buildPhase: resources` override for why explicit entries were needed)
/// so there's a single source of truth: editing either updates what this
/// screen shows with no separate sync step.
///
/// Reached only from `ProfileView`, via a plain `NavigationLink(destination:)`
/// rather than a new `AppRoute` case — same reasoning as
/// `DownloadsSettingsView`.
struct LicenseView: View {
    /// Loaded once per screen presentation, not cached — this is a rarely
    /// visited screen reading small bundled text files, not worth an
    /// `@Observable` loader for.
    private var licenseText: String {
        // Nil only if the bundled resource is ever missing — not a
        // user-facing error state worth a LoadState enum for.
        LicenseDocument.appLicense() ?? String(localized: "License text unavailable.")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                licenseBody(licenseText)
                ForEach(LicenseDocument.components(), id: \.name) { component in
                    VStack(alignment: .leading, spacing: 8) {
                        // A library's name: not localized.
                        Text(verbatim: component.name)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        licenseBody(component.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("License")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenseBody(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(.footnote, design: .monospaced))
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        LicenseView()
    }
}
#endif
