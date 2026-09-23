import Foundation

/// Human-facing version string for this build, shown on the Profile
/// screen's footer.
///
/// Sourced from `AppVersion` — a checked-in generated constant refreshed by
/// `Scripts/update-version.sh` (see VERSIONING.md), not a build-time
/// Info.plist injection. That approach was tried first (stamping
/// GitBranch/GitCommitHash into the *built* Info.plist via a
/// `postCompileScripts` phase) and confirmed broken under the current
/// Xcode build system — see `Scripts/update-version.sh`'s header comment
/// for why.
enum AppVersionInfo {
    /// `version` defaults to this build's actual `AppVersion.full`;
    /// parameterized so tests can supply a fixed value instead of
    /// depending on whatever tag/commit happened to build the test host.
    static func footerText(version: String = AppVersion.full) -> String {
        "Dionysus Player \(version)"
    }
}
