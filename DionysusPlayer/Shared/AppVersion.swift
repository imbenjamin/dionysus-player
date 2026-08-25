// GENERATED FILE — do not edit by hand.
// Regenerate with `Scripts/update-version.sh` (run whenever a version tag
// changes) — see that script's own comment and VERSIONING.md for the
// SemVer scheme this is derived from.

/// The full, human-facing SemVer for this build — always a valid SemVer
/// string, including `+build.metadata` when built off-tag. Distinct from
/// `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` (`Config/Version.xcconfig`),
/// which Apple requires to be plain dot-separated integers with no
/// prerelease suffix — this is the one source of truth those two are
/// mechanically derived from, but only this constant carries the full
/// string. Read by `AppVersionInfo` for the Profile screen footer.
enum AppVersion {
    static let full = "0.0.0-alpha.1001"
    static let build = "221"
    static let commit = "4cf9199"
}
