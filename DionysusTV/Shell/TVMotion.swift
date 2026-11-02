import SwiftUI

/// Animation for a change that moves something across the screen: the
/// sidebar opening or sliding off the edge, the player's panel rising, a
/// page scrolling back to its top. Under Reduce Motion the change lands at
/// once instead (M5). Fades and focus highlights don't move anything and
/// keep their animations.
enum TVMotion {
    static func moving(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Text and marks drawn translucent white over artwork, which hierarchical
/// styles (`.secondary`) don't cover: under Increase Contrast they're drawn
/// solid (M5). Hierarchical styles brighten by themselves.
enum TVContrast {
    static func opacity(_ designed: Double, increased: Bool) -> Double {
        increased ? 1 : designed
    }
}
