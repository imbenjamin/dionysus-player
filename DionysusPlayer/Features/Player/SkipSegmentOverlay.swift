import SwiftUI

/// The in-player "Skip Intro"/"Skip Credits"/... button: a bottom-trailing pill
/// shown while `currentTime` is inside a `PlaybackSegment`, per
/// `PlayerViewModel.currentSkipSegment`. Tapping it swaps the slot to a small
/// spinner (`isBuffering`) rather than revealing the main transport chrome's
/// buffering treatment — see `PlayerView.isSkipBuffering`.
///
/// Shares `NextUpOverlay`'s bottom-trailing slot, with the same always-mounted,
/// `isVisible`-drives-opacity treatment that view documents: this reads
/// `viewModel.currentTime` too, so mount/unmount would fight the same ~10Hz
/// re-renders, and a skip button should be available whether the transport
/// chrome is faded in or out. The two are mutually exclusive by construction —
/// `currentSkipSegment` suppresses the end-credits segment while `NextUpOverlay`
/// covers that window — so sharing a slot never picks a winner.
///
/// Dismissible by swiping the button right, or by the small close button on its
/// trailing edge (VoiceOver-only, since a raw `DragGesture` isn't reliable for
/// VoiceOver, as with `PlayerView`'s persistent Show/Hide Controls button). Both
/// route through `onDismiss`, not `onSkip`; see
/// `PlayerViewModel.dismissSkipSegment(_:)` for why dismissing doesn't seek.
struct SkipSegmentOverlay: View {
    let segment: PlaybackSegment?
    let isBuffering: Bool
    let onSkip: (PlaybackSegment) -> Void
    let onDismiss: (PlaybackSegment) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// Horizontal offset the swipe-to-dismiss gesture drives. This view is never
    /// rebuilt, so it must be reset by hand whenever a different segment takes
    /// this slot, or the next one renders pre-shifted from the last gesture. See
    /// the `onChange` below.
    @State private var dragOffset: CGFloat = 0

    /// How far right a drag must travel to count as a dismiss rather than spring
    /// back — generous enough that a small correction while reaching for the
    /// button doesn't dismiss it.
    private static let dismissSwipeThreshold: CGFloat = 60
    /// Where the button animates to once a swipe crosses the threshold: clear of
    /// any device width, so it visibly exits rather than fading in place before
    /// `onDismiss` flips `segment` to `nil` and the slot's opacity fade takes over.
    private static let dismissSlideDistance: CGFloat = 400

    private var isVisible: Bool { segment != nil || isBuffering }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                content
                    .padding(.trailing, 20)
                    // Same bottom clearance as `NextUpOverlay`'s card; see that
                    // view for why it must clear the transport row.
                    .padding(.bottom, 110)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .onChange(of: segment?.id) { _, _ in dragOffset = 0 }
    }

    @ViewBuilder
    private var content: some View {
        if isBuffering {
            // `PlayerControlsOverlay`'s buffering spinner, shrunk to this pill's
            // footprint. Shown only while the engine is actually mid-seek or
            // buffering (`PlayerView.isSkipBuffering`), not for the whole
            // `isSkippingSegment` suppression window.
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .frame(width: 20, height: 20)
                .padding(14)
                .background(Color.black.opacity(0.55), in: Circle())
        } else if let segment {
            HStack(spacing: 10) {
                // Not a `Button`: a plain view with `.onTapGesture` for the tap
                // and `.highPriorityGesture` for the swipe. A `Button` with a
                // plain `.gesture(DragGesture(...))` doesn't work — its own tap
                // recognizer wins before the drag activates, so every swipe
                // registered as a tap and fired skip instead of dismiss — and
                // mixing a raw gesture onto a `Button` also confused VoiceOver's
                // tree for the sibling close button, whose activation resolved
                // back to this one. `.highPriorityGesture` is the documented
                // pattern for a view needing both a tap and a competing gesture:
                // it wins once the drag passes `minimumDistance` and falls
                // through to the tap otherwise. `.accessibilityLabel` and
                // `.isButton` restore what a `Button` gave for free.
                Text(segment.kind.skipButtonTitle)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .offset(x: dragOffset)
                    .onTapGesture { onSkip(segment) }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                // Clamped rightward: a leftward drag isn't a
                                // dismiss gesture here.
                                dragOffset = max(0, value.translation.width)
                            }
                            .onEnded { value in
                                if value.translation.width > Self.dismissSwipeThreshold {
                                    withAnimation(.easeIn(duration: 0.2)) {
                                        dragOffset = Self.dismissSlideDistance
                                    }
                                    onDismiss(segment)
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
                    .accessibilityLabel(segment.kind.skipButtonTitle)
                    .accessibilityAddTraits(.isButton)

                // VoiceOver-only: the swipe above isn't a reliable path for
                // VoiceOver users, who need an explicit way to dismiss. A real
                // `Button` with no gesture modifier of its own — isolating it
                // from the skip element above is what fixed its VoiceOver
                // activation.
                if voiceOverEnabled {
                    Button {
                        onDismiss(segment)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Dismiss \(segment.kind.skipButtonTitle)"))
                }
            }
        }
    }
}
