import SwiftUI

/// How `SubtitleOverlayView` draws a text cue: the Dionysus look, or that look
/// with the system caption style laid over it (`SubtitleAppearance`). Plain
/// values, so the overlay never sees AetherEngine's `SubtitleCaptionStyle`;
/// `SystemCaptionStyle` makes one from it. Sizes are scaled from the overlay's
/// own `SubtitleOverlayMetrics`, so one style serves the phone and the TV.
struct SubtitleTextStyle: Equatable {
    struct RGBA: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var opacity: Double

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity) }

        static let white = RGBA(red: 1, green: 1, blue: 1, opacity: 1)
        static func black(_ opacity: Double) -> RGBA { RGBA(red: 0, green: 0, blue: 0, opacity: opacity) }
    }

    /// The system's edge styles, plus the Dionysus look's own soft shadow.
    enum Edge: Equatable {
        case softShadow, none, dropShadow, raised, depressed, outline
    }

    /// A face chosen in Settings; `nil` is the system font, semibold.
    var fontName: String?
    /// Multiplies the metrics' font size, padding and corner radius.
    var sizeScale: CGFloat = 1
    /// Opacity included.
    var textColor: RGBA = .white
    /// Whether `textColor` beats a colour the cue sets itself (an SRT
    /// `<font color>`, teletext colour): the system's "override" precedence.
    /// Otherwise the cue's colour wins, as the Dionysus look always let it.
    var textColorOverridesCue = false
    /// Applied to a cue's own colours too, as AetherEngine's software
    /// renderer does.
    var textOpacity: Double = 1
    /// The rounded panel behind the cue; `nil` draws none.
    var background: RGBA? = .black(0.55)
    /// A second, larger panel behind the background, the system's caption
    /// "window"; none by default.
    var window: RGBA?
    var edge: Edge = .softShadow

    /// What the overlay always drew.
    static let dionysus = SubtitleTextStyle()

    /// The colour for a run that carries `cueColor`; `nil` leaves the run to
    /// the cue's `textColor`.
    func runColor(_ cueColor: Color?) -> Color? {
        guard let cueColor, !textColorOverridesCue else { return nil }
        return textOpacity < 1 ? cueColor.opacity(textOpacity) : cueColor
    }
}
