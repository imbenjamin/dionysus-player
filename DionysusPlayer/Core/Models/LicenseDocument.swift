import Foundation

/// The License page's text, on iOS and the Apple TV: the app's own license,
/// then the notices of the third-party software that ships with it, each
/// under its library's name (Benjamin, 2026-10-13: so it's clear which
/// component a license refers to).
///
/// Both files are bundled from the repo root through symlinks in
/// `DionysusPlayer/Resources/` (`project.yml` forces the extensionless files
/// into Copy Bundle Resources), so editing `LICENSE` or
/// `THIRD-PARTY-NOTICES` updates the page with no sync step. In
/// `THIRD-PARTY-NOTICES` a line `# <name>` starts a library's notices.
/// It holds LibTrueHD's (MIT, and Apache-2.0 for the crates compiled into
/// it), which its license asks to ship with the app; it arrived with
/// AetherEngine 7.34.0.
enum LicenseDocument {
    /// One library's notices, shown under its name.
    struct Component: Equatable {
        let name: String
        let text: String
    }

    /// The app's own license; nil when it isn't bundled.
    static func appLicense(bundle: Bundle = .main) -> String? {
        bundled("LICENSE", in: bundle)
    }

    /// The bundled third-party notices, in file order.
    static func components(bundle: Bundle = .main) -> [Component] {
        bundled("THIRD-PARTY-NOTICES", in: bundle).map(components(in:)) ?? []
    }

    /// `notices` cut at each `# <name>` line. Anything before the first is
    /// dropped, since it would belong to no library.
    static func components(in notices: String) -> [Component] {
        var result: [Component] = []
        var name: String?
        var lines: [Substring] = []
        func close() {
            guard let name else { return }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Component(name: name, text: text))
        }
        for line in notices.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") {
                close()
                name = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                lines = []
            } else {
                lines.append(line)
            }
        }
        close()
        return result
    }

    private static func bundled(_ name: String, in bundle: Bundle) -> String? {
        bundle.url(forResource: name, withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
