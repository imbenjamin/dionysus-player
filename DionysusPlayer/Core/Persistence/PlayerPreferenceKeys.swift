import Foundation

/// `UserDefaults` keys for preferences both apps read. They lived beside the
/// iOS views that first used them, which the Apple TV target doesn't compile.

/// Profile's "Auto Carousel on Home": whether Home's hero advances by itself.
/// On by default; `HeroRailView`, `ProfileView` and the Apple TV's
/// `TVHomeView` read and write it through `@AppStorage`.
let heroAutoCarouselEnabledStorageKey = "heroAutoCarouselEnabled"
