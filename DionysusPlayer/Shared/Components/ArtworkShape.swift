import SwiftUI

/// The two corner treatments every piece of browsable artwork uses, so a
/// poster on Home, in a grid, in Search and in Downloads all round the same way.
///
/// Two sizes rather than one because a radius reads relative to what it
/// rounds. 12pt is what the Apple TV app gives a poster or card, but on a
/// 44–90pt-tall list thumbnail it eats enough of each corner that the image
/// starts to read as a pill, so rows get 8pt.
///
/// Both are `.continuous` — the squircle curve the system uses for its own
/// rounded rectangles — where artwork used to mix four radii (4, 6, 8, 8pt) on
/// the default circular curve.
///
/// Not for chrome: buttons are capsules, and the detail page's tabbed panel
/// keeps `DetailLayout.panelCornerRadius`.
extension Shape where Self == RoundedRectangle {
    /// Posters, landscape cards, library and chapter cards — anything shown as
    /// a card in a rail or grid.
    static var artworkCard: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    /// Artwork leading a list row: search results, episodes, playlist and
    /// collection members, downloads.
    static var artworkThumbnail: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }
}
