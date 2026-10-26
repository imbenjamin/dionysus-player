import SwiftUI

/// The fold of a partly folded iPhone Duo, in one view's coordinate space, or
/// nothing: flat, closed, or any other device. A reader can ask for a flat
/// display's inactive fold too (`read(from:includingInactive:)`), as the detail
/// page's spread does.
///
/// Read from the `.division` reserved region (iOS 27.1). Only an *active* one
/// counts: flat, the fold is a zero-width line Apple lets content cross; partly
/// folded, the screen bends there and nothing interactive may sit on it (HIG,
/// "Designing for iPhone Duo", Reserved regions). Measured on the simulator, the
/// band is 40pt wide centred on the inner screen's middle, and SwiftUI mirrors its
/// frame for right-to-left, so `leading`/`trailing` read correctly in both.
enum ActiveFold: Equatable {
    /// Runs side to side: held tall and propped like a laptop (tabletop).
    case horizontal(top: CGFloat, bottom: CGFloat)
    /// Runs top to bottom: held wide like a book.
    case vertical(leading: CGFloat, trailing: CGFloat)

    /// `nil` unless `frame` crosses the view, so a view that doesn't reach the
    /// fold (one half of Split View) has nothing to avoid.
    init?(frame: CGRect?, in size: CGSize) {
        guard let frame, frame.intersects(CGRect(origin: .zero, size: size)) else { return nil }
        // Whole points. A layout that moves its view by a fraction of a point
        // moves the fold in that view's space by the same amount, and an exact
        // value turns that into a feedback loop (measured on a detail page: the
        // offset doubled every pass, 0.001pt to 0.25pt, at 98% CPU on a black
        // screen). Rounded, a sub-point wobble reads as no change.
        if frame.width > frame.height {
            self = .horizontal(top: frame.minY.rounded(), bottom: frame.maxY.rounded())
        } else {
            self = .vertical(leading: frame.minX.rounded(), trailing: frame.maxX.rounded())
        }
    }

    /// The active fold in `proxy`'s space, or with `includingInactive` the fold
    /// of a flat, fully open display too. Always `nil` before iOS 27.1, which is
    /// also as far back as a foldable iPhone goes.
    nonisolated static func read(from proxy: GeometryProxy, includingInactive: Bool = false) -> ActiveFold? {
        guard #available(iOS 27.1, *) else { return nil }
        let frame = includingInactive
            ? proxy.reservedRegions(kind: .division, options: .includeInactive).first?.frame
            : proxy.reservedRegions(kind: .division).first(where: \.isActive)?.frame
        return ActiveFold(frame: frame, in: proxy.size)
    }
}

extension View {
    /// Reports this view's `ActiveFold` now and whenever it changes: folding,
    /// unfolding, rotating, resizing. The first layout pass reports no regions
    /// (measured), so read it here rather than once on appear.
    func onActiveFoldChange(includingInactive: Bool = false, _ action: @escaping (ActiveFold?) -> Void) -> some View {
        onGeometryChange(for: ActiveFold?.self, of: { ActiveFold.read(from: $0, includingInactive: includingInactive) }) { action($0) }
    }
}

/// Where the player's picture and controls go on a partly folded iPhone Duo, so
/// play/pause, the skips and the scrubber never sit on the fold, where they
/// landed when centred (measured: pause at y 457–491 in tabletop, x 462–488 in
/// book, inside the 455–495 band).
///
/// - Tabletop: the picture above the fold and every control below it, the top
///   row and logo included, so the top half is only the picture (Benjamin,
///   2026-10-26).
/// - Book: the picture keeps the whole screen; the transport row and scrubber
///   take the trailing page.
///
/// The same controls in every pose (Apple: a tabletop layout mustn't add or
/// remove features). Flat and closed are the ordinary full-screen layout.
struct PlayerFoldLayout: Equatable {
    /// The picture's height from the top edge, or `nil` for the whole screen.
    var videoHeight: CGFloat?
    /// How far down the controls start: the whole overlay, in tabletop.
    var controlsTopInset: CGFloat = 0
    /// How far in from the leading edge they start.
    var controlsLeadingInset: CGFloat = 0

    init(fold: ActiveFold?) {
        switch fold {
        case .horizontal(let top, let bottom):
            videoHeight = top
            controlsTopInset = bottom
        case .vertical(_, let trailing):
            controlsLeadingInset = trailing
        case nil:
            break
        }
    }
}
