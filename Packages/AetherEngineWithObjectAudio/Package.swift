// swift-tools-version: 6.1

import PackageDescription

// AetherEngine with its two object-audio components switched on, so TrueHD
// Atmos and DTS:X can keep their height channels as Spatial Audio
// (`LoadOptions.objectAudioRendering`). They are package traits, off by
// default since AetherEngine 7.39.0, and XcodeGen can't set a remote
// package's traits (2.45.4 drops a `traits:` key without a word), so the app
// depends on this local package instead of on AetherEngine directly. It is
// AetherEngine's own suggestion (README › Optional components) and the shape
// of its `Probes/AllTraits`.
//
// **This is where AetherEngine is pinned.** Exactly (`exact:`), never a
// range: `Package.resolved` is gitignored with the generated project, so
// every CI run resolves cold, and a range let CI land on whatever release was
// newest with no commit here (PR #147: `6.54.0` resolved against a `6.52.0`
// pin). The weekly "Bump AetherEngine" workflow
// (`.github/workflows/aetherengine-bump.yml`) finds the newest release tag
// within the current major and opens a PR bumping the `exact:` line below. A
// major bump (e.g. 8.0.0) is where AetherEngine's public API may break, so the
// workflow never proposes one: that stays a deliberate manual edit here. The
// last one, 6.x → 7.x (2026-09-23), renamed no public symbols but raised
// AetherEngine's platform floor to iOS 18, which is why every
// `deploymentTarget` in `project.yml` moved from 17.0 to 18.0 alongside it.
//
// The "AetherEngine Version" row in Playback Stats reads `AetherEngine.version`
// from the linked engine, so there is no constant elsewhere to keep in step.
//
// The components may be subject to third-party patent licensing (AetherEngine
// 7.39.0's notes); Benjamin accepted that on 2026-10-19. LibTrueHD's notices
// are in THIRD-PARTY-NOTICES. DTS:X is decoded by FFmpeg's own `dca` decoder
// (FFmpegBuild 3.9.0's height patch) since AetherEngine 7.44.0, which dropped
// LibDTSX: its LGPL-3.0 `DTSX.framework` couldn't ship in an App Store app.
let package = Package(
    name: "AetherEngineWithObjectAudio",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
    ],
    products: [
        .library(name: "AetherEngineWithObjectAudio", targets: ["AetherEngineWithObjectAudio"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/superuser404notfound/AetherEngine",
            exact: "7.47.0",
            traits: ["TrueHDObjectAudio", "DTSXObjectAudio"]
        ),
    ],
    targets: [
        .target(
            name: "AetherEngineWithObjectAudio",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
