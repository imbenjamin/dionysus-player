import SwiftUI

/// Displays the app's privacy policy, bundled from the repo's own
/// `PRIVACY.md` (`DionysusPlayer/Resources/PRIVACY.md` is a symlink to it,
/// not a copy — same single-source-of-truth pattern as `LicenseView`'s
/// `LICENSE`) so there's no separate copy to keep in sync.
///
/// Unlike `LicenseView` (preformatted legal text, shown as a monospaced
/// literal dump), this file is prose Markdown, rendered line-by-line below
/// rather than parsed as one `AttributedString(markdown:)` document — that
/// whole-document approach was tried first, but `Text` doesn't insert any
/// visible line break between block-level elements (headers, paragraphs,
/// list items) when a single parsed `AttributedString` mixes them, so the
/// entire document ran together on one line. Parsing line-by-line instead,
/// with `.inlineOnlyPreservingWhitespace` (bold/italic/links parsed, but
/// whitespace/newlines kept literal), keeps every source line break intact;
/// `#`-headers and `- `-bullets are stripped/re-styled by hand since
/// there's no block parser doing it for us this way.
///
/// Reached only from `ProfileView`, via a plain `NavigationLink(destination:)`
/// — same reasoning as `DownloadsSettingsView`/`LicenseView`.
struct PrivacyPolicyView: View {
    /// Loaded once per screen presentation, not cached — same reasoning as
    /// `LicenseView.licenseText`.
    private var privacyText: AttributedString {
        guard
            let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
            let raw = try? String(contentsOf: url, encoding: .utf8)
        else {
            // Should only happen if the bundled resource is ever missing —
            // not a user-facing error state worth a LoadState enum for.
            return AttributedString(String(localized: "Privacy policy text unavailable."))
        }

        var result = AttributedString()
        let lines = raw.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result += AttributedString("\n")
                continue
            }

            var headerLevel = 0
            var content = trimmed
            while content.hasPrefix("#") {
                headerLevel += 1
                content.removeFirst()
            }
            content = content.trimmingCharacters(in: .whitespaces)

            var bulletPrefix = ""
            if content.hasPrefix("- ") {
                bulletPrefix = "•  "
                content.removeFirst(2)
            }

            var parsedLine = (try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(content)
            if headerLevel > 0 {
                parsedLine.font = headerLevel <= 1 ? .title2.bold() : .headline
            }

            if !bulletPrefix.isEmpty {
                result += AttributedString(bulletPrefix)
            }
            result += parsedLine
            if index < lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            Text(privacyText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
}
#endif
