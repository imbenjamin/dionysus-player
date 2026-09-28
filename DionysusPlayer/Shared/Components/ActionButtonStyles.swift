import SwiftUI

/// The two button treatments a detail page's action row uses — Play/Resume as
/// the one prominent control, everything beside it as a quiet peer.
///
/// Both are capsules or circles, matching the onboarding journey's buttons and
/// iOS 26's own default shape for large controls. The action row used to be
/// 12pt rounded rectangles with a pastel brand tint on the secondary buttons,
/// which made the first screen after onboarding the one place the button
/// language changed, and put the loudest colour on the page (after Play) on a
/// secondary action.
extension View {
    /// Play/Resume: filled with the brand colour, full-width at the call site.
    func primaryActionButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.dionysusPrimary)
            .controlSize(.large)
    }

    /// Restart, Download and the season download button: an icon-only circle
    /// in neutral grey, so colour stays with the primary action. See
    /// `SecondaryActionButtonStyle`. A titled secondary button, such as an
    /// error state's Close, passes `.capsule`.
    func secondaryActionButtonStyle(
        controlSize: ControlSize = .large,
        shape: ButtonBorderShape = .circle
    ) -> some View {
        modifier(SecondaryActionButtonStyle(controlSize: controlSize, shape: shape))
    }
}

/// See `secondaryActionButtonStyle(controlSize:)`.
///
/// `.bordered`, not `.glass`, on iOS 26 as well: these buttons sit on a
/// detail page's plain background, where there's nothing behind the glass to
/// refract, and a glass circle measured as a white disc on white with only a
/// faint shadow to find it by.
///
/// `.bordered` paints both its fill and its label from the tint, and each stack
/// is tinted `dionysusPrimary` (`stableContentTint()`). The tint is therefore
/// half-opacity label colour — which `.bordered` turns into a light grey fill,
/// close to the system fill colours in either appearance — and the label is set
/// back to full `.primary` separately.
private struct SecondaryActionButtonStyle: ViewModifier {
    let controlSize: ControlSize
    let shape: ButtonBorderShape

    func body(content: Content) -> some View {
        content
            .buttonStyle(.bordered)
            .buttonBorderShape(shape)
            .controlSize(controlSize)
            .tint(.primary.opacity(0.5))
            .foregroundStyle(.primary)
    }
}

extension View {
    /// The watched-so-far bar on a part-watched Play/Resume button, shared by
    /// the streaming and offline rows. `nil` draws nothing.
    ///
    /// Inset inside the capsule on its own faint track rather than running
    /// along the button's bottom edge as it did on the old rounded rectangle:
    /// a capsule's ends curve away across most of its height, so an edge bar
    /// would lose both ends to the clip, and for a few percent watched there
    /// would be nothing left to see. The track keeps the inset bar reading as
    /// progress rather than as an underline.
    ///
    /// The 20pt side inset clears a large capsule's end curve (radius ~25pt)
    /// at this height with room to spare.
    func resumeProgressOverlay(_ fraction: Double?) -> some View {
        overlay(alignment: .bottom) {
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.dionysusProgress.opacity(0.35))
                        Capsule().fill(Color.dionysusProgress)
                            .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 3))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}
