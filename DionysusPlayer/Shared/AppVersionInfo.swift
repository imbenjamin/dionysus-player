import Foundation

/// The git branch/commit this build was actually built from, for display
/// (Profile screen footer) rather than debugging tools.
///
/// Xcode has no built-in way to surface this, so `project.yml`'s
/// `prebuildScripts` stamps `GitBranch`/`GitCommitHash` into the *built*
/// Info.plist at build time — see the comment there for why it's a prebuild
/// script and not a post-build one (code signing).
enum AppVersionInfo {
    /// `info` defaults to the running app's own Info.plist; parameterized so
    /// tests can supply a fixed dictionary instead of depending on whatever
    /// branch/commit happened to build the test host.
    static func footerText(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let branch = info?["GitBranch"] as? String ?? "unknown"
        let commit = info?["GitCommitHash"] as? String ?? "unknown"
        return "Dionysus Player \(branch) (\(commit))"
    }
}
