import UIKit

extension UIView {
    /// Walks `superview` upward until the first `UIScrollView` ancestor,
    /// or `nil` if none is found before reaching the top. Shared by
    /// `HeroRailView`'s `RegionTouchObserver.Coordinator` and `HomeView`'s
    /// `ScrollBottomObserver.Coordinator` — both attach a marker view as a
    /// `.background` on a SwiftUI `ScrollView`'s content and need to find
    /// that scroll view's own backing `UIScrollView` from there, robust to
    /// SwiftUI changing exactly how many wrapper views it inserts between
    /// them across versions. See either coordinator's own doc comment for
    /// why walking up from a content-side marker (rather than the
    /// `ScrollView` container itself) is what actually finds the right one.
    func nearestScrollViewAncestor() -> UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }
}
