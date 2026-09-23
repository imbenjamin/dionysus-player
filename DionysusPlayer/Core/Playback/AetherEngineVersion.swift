import AetherEngine

/// The AetherEngine release this build links, for `PlaybackStatsOverlay`'s
/// "AetherEngine Version" row.
///
/// Forwards `AetherEngine.version` (7.3.0+), which upstream rewrites in each
/// release's prep commit and holds in step with the tag by test — checked
/// against every tag from 7.3.0 to 7.15.0 when this replaced the generated
/// constant that used to live here. It exists so feature code can show the
/// version without importing the engine; see `PlaybackEngine`.
enum AetherEngineVersion {
    static let current = AetherEngine.version
}
