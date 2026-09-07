import SwiftUI

/// The in-player "Skip Intro"/"Skip Recap"/"Skip Preview"/"Skip Commercial"/
/// "Skip Credits" button — a bottom-trailing pill shown while `currentTime`
/// is inside a `PlaybackSegment`, per `PlayerViewModel.currentSkipSegment`.
/// Tapping it swaps the same slot to a small spinner (`isBuffering`) rather
/// than reverting to the main transport chrome's own buffering treatment —
/// see `PlayerView.isSkipBuffering`'s doc comment for why a segment skip is
/// deliberately kept from revealing that chrome at all.
///
/// Mounted in the same bottom-trailing slot `NextUpOverlay` occupies, with
/// the identical "always mounted, `isVisible` drives `.opacity`/
/// `.allowsHitTesting`, not gated by `showControls`" treatment that view
/// documents — same reasoning applies verbatim here: this reads
/// `viewModel.currentTime` too, so a mount/unmount toggle would fight the
/// same ~10Hz time-update re-renders, and a skip button (and the spinner
/// that follows it) are meant to be available whether the rest of the
/// transport chrome is faded in or out. The two overlays are mutually
/// exclusive by construction — `currentSkipSegment` suppresses the
/// end-credits segment specifically whenever `NextUpOverlay` is covering
/// that window instead — so sharing a slot never means picking a winner
/// between two visible cards.
///
/// Dismissible two ways, both routed through `onDismiss` rather than
/// `onSkip` — see `PlayerViewModel.dismissSkipSegment(_:)`'s doc comment for
/// why dismissing deliberately doesn't seek: swipe the button itself away to
/// the right, or (VoiceOver-only, since a raw `DragGesture` isn't a reliable
/// path for VoiceOver — same reasoning as `PlayerView`'s own persistent
/// Show/Hide Controls button) tap the small close button that appears
/// attached to its trailing edge.
struct SkipSegmentOverlay: View {
    let segment: PlaybackSegment?
    let isBuffering: Bool
    let onSkip: (PlaybackSegment) -> Void
    let onDismiss: (PlaybackSegment) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// Horizontal offset the swipe-to-dismiss gesture drives — lives here
    /// rather than tracked per-segment because this view is never rebuilt
    /// (see this type's own doc comment on why it stays mounted), so it has
    /// to be reset by hand whenever a *different* segment starts occupying
    /// this slot, or the next one would render pre-shifted from whatever
    /// gesture last touched this button. See the `onChange` below.
    @State private var dragOffset: CGFloat = 0

    /// How far right a drag has to travel before it counts as a dismiss
    /// rather than springing back — generous enough that an incidental
    /// touch/small correction while reaching for the button doesn't
    /// dismiss it by accident.
    private static let dismissSwipeThreshold: CGFloat = 60
    /// Where the button animates to once a swipe crosses the threshold —
    /// comfortably clear of any device width so it visibly exits rather
    /// than just fading in place, before `onDismiss` flips `segment` to
    /// `nil` and the whole slot's own opacity fade (below) takes over.
    private static let dismissSlideDistance: CGFloat = 400

    private var isVisible: Bool { segment != nil || isBuffering }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                content
                    .padding(.trailing, 20)
                    // Same bottom clearance as `NextUpOverlay`'s card — see
                    // that view's own doc comment on why it needs to clear
                    // the transport row.
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
            // Same visual language as `PlayerControlsOverlay`'s own
            // buffering spinner, shrunk to fit this slot's pill footprint —
            // shown "if necessary" only (`PlayerView.isSkipBuffering`
            // requires the engine to actually be mid-seek/-buffer right
            // now), not for the whole `isSkippingSegment` suppression
            // window unconditionally.
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .frame(width: 20, height: 20)
                .padding(14)
                .background(Color.black.opacity(0.55), in: Circle())
        } else if let segment {
            HStack(spacing: 10) {
                // Deliberately *not* a `Button` — a plain view with
                // `.onTapGesture` for the tap and `.highPriorityGesture` for
                // the swipe. Confirmed live (2026-08-27): a `Button` with a
                // plain `.gesture(DragGesture(...))` attached doesn't work —
                // the button's own built-in tap recognizer wins before the
                // drag ever gets a chance to activate, so every swipe just
                // registered as a tap (skip fired instead of dismiss), and
                // mixing a raw gesture onto a `Button` also seemed to
                // confuse VoiceOver's accessibility tree for the *sibling*
                // close button below, whose activation kept resolving back
                // to this one instead. `.highPriorityGesture` is Apple's own
                // documented pattern for "this view needs both a tap and a
                // competing gesture" — it explicitly wins recognition over
                // the view's own tap once the drag passes `minimumDistance`,
                // falling through to the tap otherwise. `.accessibilityLabel`/
                // `.accessibilityAddTraits(.isButton)` restore what a real
                // `Button` would have given this for free, since it's no
                // longer one.
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
                                // Clamped to the right only — "swipe away to
                                // the right" is the whole ask; a leftward
                                // drag isn't a dismiss gesture here.
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

                // VoiceOver-only — see this type's own doc comment for why
                // the swipe gesture above isn't a reliable substitute for
                // VoiceOver users, who need an explicit, always-reachable
                // way to dismiss without depending on a raw drag. A real
                // `Button`, untouched by any gesture modifier of its own —
                // isolating it from the skip element above is exactly what
                // fixed its VoiceOver activation, per this view's own doc
                // comment.
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
