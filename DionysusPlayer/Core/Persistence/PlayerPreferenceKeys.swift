import Foundation

/// `UserDefaults` keys for preferences both apps read. They lived beside the
/// iOS views that first used them, which the Apple TV target doesn't compile.

/// Profile's "Auto Carousel on Home": whether Home's hero advances by itself.
/// On by default; `HeroRailView`, `ProfileView` and the Apple TV's
/// `TVHomeView` read and write it through `@AppStorage`.
let heroAutoCarouselEnabledStorageKey = "heroAutoCarouselEnabled"

/// This default and `ProfileView`'s `@AppStorage` default are declared by hand
/// in both places, with nothing enforcing they stay in sync.
let chaptersInScrubberEnabledStorageKey = "chaptersInScrubberEnabled"
/// Chapters in the scrubber are opt-out, matching every other chapter surface —
/// the rail, the current-chapter button, the picker — being on whenever chapters
/// exist. This one is escapable for anyone who finds the snap distracting.
let chaptersInScrubberEnabledDefault = true

let showPlaybackStatsButtonEnabledStorageKey = "showPlaybackStatsButtonEnabled"

/// On in debug builds, off in release. `PlayerControlsOverlay`'s `@AppStorage`
/// read of this key and `AdvancedPlaybackSettingsView`'s Toggle must declare
/// the same default to agree before the setting is ever visited — same
/// reasoning as `hero3DDepthEnabledStorageKey` in `HeroHeaderView.swift`.
#if DEBUG
let showPlaybackStatsButtonEnabledDefault = true
#else
let showPlaybackStatsButtonEnabledDefault = false
#endif
