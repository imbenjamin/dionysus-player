import CoreGraphics
import SwiftUI

struct PlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    @Binding var isScrubbing: Bool
    @Binding var scrubTime: TimeInterval
    /// Whether the audio/subtitle track picker (`trackSelectionButton`) is
    /// showing — a `@Binding`, not local `@State` like the picker's other
    /// state (`trackPickerPage`), because `PlayerView`'s auto-hide timer
    /// needs to know about it too: without this, the timer had no way to
    /// tell the picker was open and would fade the whole controls row out
    /// from under it a few seconds in, panel and all. See
    /// `PlayerView.scheduleAutoHide()`.
    @Binding var isShowingTrackPicker: Bool
    var onClose: () -> Void
    /// Whether `RotationLock` currently has rotation locked. Plain state
    /// owned by `PlayerView`, not a `@Binding` — this button only ever
    /// reports a tap via `onToggleRotationLock`, the same "closure out,
    /// value in" shape `onClose` already uses, since (unlike the scrubber)
    /// there's no continuous in-overlay gesture that needs to write back to
    /// it directly.
    var isRotationLocked: Bool
    var onToggleRotationLock: () -> Void
    /// Whether `PlaybackStatsOverlay` is currently showing — same "plain
    /// state in, closure out" shape as `isRotationLocked`/
    /// `onToggleRotationLock` above, for the same reason: this button only
    /// ever reports a tap, `PlayerView` owns the actual toggle.
    var isPlaybackStatsVisible: Bool
    var onTogglePlaybackStats: () -> Void
    /// A one-shot action, unlike the two toggle buttons above — there's no
    /// "currently in PiP" state to mirror here, `viewModel
    /// .isPictureInPicturePossible` alone decides whether the button is
    /// enabled at all, and once tapped there's nothing left for this overlay
    /// to reflect (the "Playing in Picture in Picture" placeholder lives in
    /// `PlayerView`, keyed off `viewModel.isPictureInPictureActive`).
    var onEnterPictureInPicture: () -> Void
    /// Called on every button tap and scrubber-drag tick — `PlayerView`
    /// uses this to reset its auto-hide countdown, so a button press or an
    /// in-progress drag doesn't get cut off by the fade mid-interaction. Not
    /// called from `onClose` (playback is ending) or the timestamp-toggle
    /// button (doesn't affect anything visible enough to warrant resetting
    /// the timer over).
    var onInteract: () -> Void
    /// A tap that landed on blank space within this overlay — not on any
    /// button/scrubber/picker — while the controls are visible. `PlayerView`
    /// hides them immediately (with the same fade `scheduleAutoHide()`'s
    /// timer uses) rather than making the user wait out the full auto-hide
    /// delay. See `body`'s own full-overlay blank-space tap catcher for why
    /// a plain tap gesture there is enough to only catch *blank* taps —
    /// actual buttons/the scrubber/the track picker's own backdrop all sit
    /// above it and claim their own taps first.
    var onDismissControls: () -> Void

    /// Whether the scrubber's trailing timestamp reads as a `-`-prefixed
    /// countdown to the end (the default) or the asset's total duration —
    /// flipped by tapping that timestamp. Local `@State`: nothing outside
    /// this overlay needs to know which mode is showing.
    @State private var showRemainingTime = true

    /// Whether a touch is actively down on the scrubber track, as opposed to
    /// `isScrubbing` (the binding), which now stays `true` a little longer —
    /// through the just-issued seek landing, not just through the drag
    /// itself. See `scrubberTrack`'s gesture and the `onChange`s below for
    /// why the two need to be separate. Local: nothing outside this overlay
    /// needs to know a touch is down specifically, only that scrubbing (in
    /// the broader sense) is in progress.
    @State private var isDraggingScrubber = false

    /// Latest resolved scrub-preview still, shown by `ScrubThumbnailPreview`
    /// while `isDraggingScrubber`. Deliberately not cleared between fetches
    /// — a `nil` result from `viewModel.scrubThumbnail(atSeconds:)` means
    /// "not available yet", not "no thumbnail exists", so this keeps
    /// whatever it last had rather than flashing blank. Reset only
    /// implicitly, by the next drag's first successful fetch overwriting it.
    @State private var scrubThumbnailImage: CGImage?
    /// A scheduled/in-flight scrub-thumbnail fetch, or `nil` when none is
    /// pending — see `requestScrubThumbnail(at:)`'s doc comment for the
    /// throttle (not debounce) shape this drives.
    @State private var scrubThumbnailTask: Task<Void, Never>?
    /// The latest drag position requested — always kept current by every
    /// `.onChanged` tick, independent of whether a fetch is actually
    /// scheduled right now. When a throttled fetch finally runs, it reads
    /// *this* rather than whatever position was current when it was
    /// scheduled, so a burst of ticks collapses into one fetch at the
    /// drag's latest position rather than a stale in-between one.
    @State private var pendingScrubSeconds: TimeInterval?
    /// When the last scrub-thumbnail fetch actually started — the
    /// throttle's own clock, measured from real elapsed time rather than
    /// "time since the last drag tick" (which is what a debounce, the
    /// shape this replaced, would key off instead).
    @State private var lastScrubThumbnailFireDate: Date?

    /// A fixed cap on the track picker panel's height, *not* a measured
    /// half of the real screen height — every attempt to read the real
    /// screen height via `GeometryReader`/`PreferenceKey` (a `GeometryReader`
    /// as `body`'s root, then a `.background(GeometryReader{...})`
    /// measurement instead) ended with the panel rendering nowhere at all;
    /// the common factor across every failure was *some* `GeometryReader`/
    /// `PreferenceKey` still in play somewhere in this view, which is why
    /// `estimatedHeight(for:)` below is a plain arithmetic estimate rather
    /// than a measurement too. Landscape iPhones (this player's primary
    /// orientation) comfortably clear this fixed cap in practice.
    private static let trackPickerMaxHeight: CGFloat = 320
    /// The panel's own width — named alongside `trackPickerMaxHeight` rather
    /// than left as bare literals on `trackPickerContent`'s `.frame(...)`,
    /// matching every other picker sizing constant here.
    private static let trackPickerIdealWidth: CGFloat = 320
    private static let trackPickerMaxWidth: CGFloat = 360

    /// Shared open/close transition for the track picker panel — one
    /// constant so the open and close feel identical rather than drifting
    /// apart across the several call sites that toggle `isShowingTrackPicker`
    /// (the button, the backdrop tap, each row's selection). Reintroduced
    /// after confirming the panel reliably shows *without* it — see
    /// `trackSelectionButton`'s doc comment on why a `.transition` was the
    /// first thing stripped out while diagnosing that.
    private static let trackPickerAnimation: Animation = .easeOut(duration: 0.18)

    /// Drill-down/back navigation between picker pages, distinct from
    /// `trackPickerAnimation` above — slower and `.easeInOut` rather than
    /// `.easeOut`, matching `UINavigationController`'s own push/pop timing
    /// (~0.3s, symmetric acceleration) rather than the snappier pop-open
    /// feel appropriate for the panel itself appearing/disappearing.
    private static let trackPickerNavigationAnimation: Animation = .easeInOut(duration: 0.3)

    var body: some View {
        ZStack {
            // Purely decorative, drawn *behind* the blank-space tap catcher
            // below — deliberately its own backmost `ZStack` sibling here,
            // not attached to `content` via `.background()` the way it used
            // to be. A `.background()`'s drawn content (this gradient is
            // real pixels, not `Color.clear`) occludes hit-testing for
            // whatever sits behind *it* — so with the gradient attached to
            // `content` (the frontmost sibling), it silently blocked every
            // tap meant for the catcher below across the *entire* overlay,
            // not just where the gradient visually reads as opaque. Pulling
            // it out to be the actual backmost layer removes that occluder
            // entirely: nothing but the catcher and real controls sit in
            // front of the screen from here on.
            backgroundGradient

            // Full-overlay, effectively-invisible blank-space tap
            // catcher — sits between the decorative background above and
            // `content` below, so every real control in `content` (drawn
            // in front of it, next) claims its own tap first via ordinary
            // SwiftUI front-to-back hit-test resolution; this only ever
            // receives a tap that landed on space nothing else wanted.
            // `onDismissControls` hides the controls immediately — see
            // that closure's own doc comment.
            //
            // Replaces an earlier version of this idea that only armed
            // the middle band (the `Spacer()`s around `transportControls`)
            // and deliberately left `topSection`'s and `scrubberBar`'s own
            // blank space uncaught. That left a real gap: a tap on truly
            // blank space *within* those two rows fell straight through
            // this overlay (neither row has its own `.contentShape`, and a
            // plain `VStack` only hit-tests drawn content) to `PlayerView`'s
            // video-surface gesture underneath, which only *toggles*
            // `showControls` — not a reliable hide — and only after the
            // system's double-tap disambiguation window elapses.
            // `topSection`/`scrubberBar` are fixed-height regardless of
            // orientation while the whole overlay is much shorter in
            // landscape, so that fallthrough ate a proportionally much
            // bigger share of the screen there — exactly why "tap blank
            // space to dismiss" read as unreliable especially in
            // landscape. Covering the *entire* overlay here removes that
            // gap without any manual region bookkeeping: "isn't on an
            // interactive element" now falls out for free from z-order
            // plus every real control's own guaranteed ≥44×44pt
            // `.contentShape` (see each button's doc comment) rather than
            // a hand-carved "protected band."
            //
            // Needs its own opaque-enough-to-hit-test fill, not plain
            // `.clear` — same reasoning as the track-picker backdrop below
            // (SwiftUI won't hit-test a fully `.clear` shape).
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Defensive: the track picker's own backdrop (below,
                    // added via a later `.overlay` and therefore already
                    // on top) should always claim a tap first while open,
                    // but guard here too rather than rely solely on
                    // z-order.
                    guard !isShowingTrackPicker else { return }
                    onDismissControls()
                }

            content
        }
        // Full-screen, effectively-invisible tap catcher — placed in its own
        // `.overlay` *before* the panel's below, so the panel (added after,
        // and therefore on top) still receives its own taps while any tap
        // elsewhere on screen falls through to this and closes the picker.
        // Needs its own opaque-enough-to-hit-test fill (SwiftUI won't
        // hit-test a fully `.clear` shape) but visually reads as nothing —
        // without it, a tap meant to dismiss the picker would instead reach
        // the blank-space catcher above (or, before this overlay ever
        // mounted, `PlayerView`'s own single-tap gesture on the video
        // surface underneath) and close the whole controls overlay on top
        // of closing the picker.
        .overlay {
            if isShowingTrackPicker {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if isShowingTrackPicker {
                trackPickerContent
                    // Approximate clearance for the top button row + its
                    // padding, not a measured value — the row's own height
                    // varies a little with Dynamic Type, so this is a
                    // reasonable anchor rather than a pixel-exact one.
                    .padding(.top, 76)
                    .padding(.trailing, 20)
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
            }
        }
    }

    /// `topSection`/`transportControls`/`scrubberBar` stacked as before —
    /// pulled out of `body` only so the new blank-space tap catcher there
    /// can sit behind it as a `ZStack` sibling. Deliberately carries no
    /// `.background()` of its own anymore — see `backgroundGradient`'s doc
    /// comment for why that moved out to its own layer — so this is purely
    /// the real, interactive content: wherever it has nothing drawn (the
    /// `Spacer()` gaps), a tap correctly falls straight through to the
    /// catcher behind it, same as it always has for a bare `VStack`.
    private var content: some View {
        VStack {
            topSection

            VStack {
                Spacer()
                transportControls
                Spacer()
            }

            scrubberBar
        }
    }

    /// The corner-anchored logo gradient + bottom darkening, previously
    /// attached to `content` via `.background()`. Moved out to be its own
    /// backmost `ZStack` sibling in `body` rather than staying attached
    /// there — see `body`'s own doc comment for why: a `.background()`'s
    /// drawn content (this is real gradient pixels, not `Color.clear`)
    /// occludes hit-testing for whatever's behind *it*, which silently
    /// blocked the blank-space tap catcher across the whole overlay once
    /// that catcher became a `ZStack` sibling rather than something inside
    /// `content` itself. As its own backmost layer here, nothing sits
    /// between the screen and this decoration, so it can no longer occlude
    /// anything.
    private var backgroundGradient: some View {
        ZStack {
            // Corner-anchored, sitting mainly under the logo — see
            // `topSection`'s doc comment for why this lives here, on
            // the *whole* overlay, rather than scoped to that section's
            // own (much shorter) frame. A flat plateau out to 45% of
            // the radius, rather than fading immediately from the
            // corner, is deliberate: `.topLeading` is the *screen's*
            // true corner (this background ignores the safe area — see
            // below), which sits some distance above/left of the
            // logo's own safe-area-respecting position. A simple
            // 2-stop fade was already noticeably dimmer by the time it
            // reached that far, undershooting exactly the area this is
            // meant to cover; holding near-full opacity out past where
            // the logo actually sits, before tapering off, fixes that
            // without reintroducing a hard-edged cutoff — it still
            // reaches `.clear` well within the endRadius.
            //
            // Stretched wider than tall via `.scaleEffect` — a logo
            // wordmark is typically much wider than it is high (e.g.
            // "Office Space"), so a plain circular `RadialGradient`
            // left its right half sitting on unfaded video well before
            // the gradient's own falloff caught up, confirmed against a
            // real wide logo. Scaling from `.topLeading` keeps the
            // anchor corner fixed and stretches the circle into an
            // ellipse that reaches proportionally further right than
            // down, matching a wordmark's own proportions instead of a
            // uniform circle's.
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .black.opacity(0.85), location: 0),
                    .init(color: .black.opacity(0.85), location: 0.45),
                    .init(color: .clear, location: 1)
                ]),
                center: .topLeading,
                startRadius: 0,
                endRadius: 450
            )
            .scaleEffect(x: 1.8, y: 1, anchor: .topLeading)

            // Bottom-only — the scrubber's own legibility now comes
            // from `scrubberTrack`'s explicit track colors, not from
            // darkening behind it further.
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Without this, the gradient is sized/positioned to this view's own
        // safe-area-respecting frame, not the true screen bounds — same
        // video-surface treatment `PlayerView` already gives the player's
        // video layer. Left off, the gradient falls short of the physical
        // edges (most visible in landscape, where the safe-area inset is on
        // the corner side this gradient is meant to bleed into). The
        // buttons/logo/scrubber themselves stay out of this — only this
        // decorative layer ignores the safe area, so controls still avoid
        // the sensor housing/home indicator the way they should.
        .ignoresSafeArea()
        // Purely decorative — explicitly not part of hit-testing (belt and
        // braces alongside moving it behind the catcher above; harmless
        // either way since nothing here has a gesture attached).
        .allowsHitTesting(false)
    }

    /// Close/track-selection buttons and the logo/title row. The
    /// corner-anchored gradient behind them lives on the *whole overlay's*
    /// background (the `ZStack` in `body`), not scoped to this section's
    /// own `VStack` — that was tried first and clipped the gradient hard:
    /// `.background()` clips its content to the view it's attached to, and
    /// this section's own frame (button row + logo, no `Spacer()`s) is only
    /// as tall as its content — well under the gradient's 320pt radius — so
    /// the fade got cut off mid-way instead of reaching `.clear`, visible
    /// as a hard horizontal line right under the logo. The *whole* overlay
    /// is comfortably taller than 320pt, so anchoring it there instead lets
    /// the same gradient actually finish fading out inside its own bounds.
    private var topSection: some View {
        VStack {
            HStack {
                // A proper close button, not a minimize/collapse affordance —
                // `onClose` always stops playback and reports a resume point
                // to the server (`PlayerViewModel.stop()`), it never leaves
                // the session running in the background, so the icon should
                // read as "exit playback" rather than "tuck this away".
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.title2)
                        // Pads the drawn glyph out to HIG's 44×44 minimum
                        // touch target — see `body`'s blank-space tap
                        // catcher doc comment for why every real control
                        // here now needs an explicit, reliable tap target:
                        // once blank space anywhere is tappable-to-dismiss,
                        // a control with a smaller-than-drawn hit area is
                        // easy to narrowly miss and misfire a dismiss
                        // instead. Same pattern `ProfileView.swift`'s
                        // GitHub link uses.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }

                Spacer()

                // Grouped with its own spacing rather than relying on the
                // outer `HStack`'s (there's only ever been one trailing
                // button until now) — matches the touch-target spacing
                // `transportControls` already uses between its three
                // buttons.
                HStack(spacing: 20) {
                    Button {
                        onInteract()
                        onToggleRotationLock()
                    } label: {
                        // The open/closed padlock swap alone (no background
                        // change) turned out too subtle to notice at a
                        // glance against a busy, constantly-changing video
                        // frame — confirmed against a real device. Locked
                        // now also gets a solid white "badge" behind it
                        // (glyph flips to black for contrast on top of
                        // that), the same active/on-state affordance a
                        // system control center toggle uses; unlocked stays
                        // a plain icon with no chrome, matching every other
                        // button in this row.
                        Image(systemName: isRotationLocked ? "lock.rotation" : "lock.rotation.open")
                            .font(.title2)
                            .foregroundStyle(isRotationLocked ? .black : .white)
                            .frame(width: 36, height: 36)
                            .background {
                                if isRotationLocked {
                                    Circle().fill(Color.white)
                                }
                            }
                            // The visible badge stays 36×36 — only the tap
                            // target grows, via an outer frame the badge is
                            // centered in, to HIG's 44pt minimum. See the
                            // close button above for why this matters now.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(isRotationLocked ? Text("Unlock rotation") : Text("Lock rotation"))
                    .animation(.easeInOut(duration: 0.15), value: isRotationLocked)

                    trackSelectionButton

                    // Omitted entirely rather than shown disabled — PiP is
                    // only ever unavailable because the active session is on
                    // AetherEngine's software route (see `PlaybackEngine
                    // .onPictureInPicturePossibleChange`'s doc comment) or
                    // because AVKit hasn't yet reported the layer ready, and
                    // neither is a state worth surfacing an inert button for.
                    if viewModel.isPictureInPicturePossible {
                        Button {
                            onInteract()
                            onEnterPictureInPicture()
                        } label: {
                            Image(systemName: "pip.enter")
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Picture in Picture"))
                    }

                    // Same active/on-state badge treatment as the rotation
                    // lock button above — a plain glyph swap alone proved
                    // too subtle against a busy video frame for that one
                    // (see its own comment), and this is the same kind of
                    // persistent-until-toggled-again state.
                    Button {
                        onInteract()
                        onTogglePlaybackStats()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.title2)
                            .foregroundStyle(isPlaybackStatsVisible ? .black : .white)
                            .frame(width: 36, height: 36)
                            .background {
                                if isPlaybackStatsVisible {
                                    Circle().fill(Color.white)
                                }
                            }
                            // Same 36pt-badge-inside-a-44pt-target treatment
                            // as the rotation lock button above.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(isPlaybackStatsVisible ? Text("Hide playback stats") : Text("Show playback stats"))
                    .animation(.easeInOut(duration: 0.15), value: isPlaybackStatsVisible)
                }
            }
            .foregroundStyle(.white)
            .padding()

            titleRow
        }
    }

    /// Which page of the track picker is showing — `.root` (the
    /// "Audio"/"Subtitles" entry rows) when both categories have a choice to
    /// make, one of the leaf pages otherwise (see `trackSelectionButton`,
    /// which skips straight to the one applicable leaf rather than showing a
    /// `.root` page with a single row on it). Reset by
    /// `trackSelectionButton`'s tap handler every time the picker opens, so
    /// it never reopens mid-drill-down from wherever it was left last time.
    private enum TrackPickerPage: Equatable {
        case root
        case audio
        case subtitle
    }

    @State private var trackPickerPage: TrackPickerPage = .root

    /// A leaf page's identity — narrower than `TrackPickerPage`, which also
    /// has a `.root` case with no equivalent here. `displayedLeafPage` below
    /// is never root (see its own doc comment), so this type makes that
    /// invariant structural rather than relying on an "unreachable" `switch`
    /// case that has to be trusted by inspection.
    private enum TrackPickerLeaf {
        case audio
        case subtitle

        var page: TrackPickerPage {
            switch self {
            case .audio: return .audio
            case .subtitle: return .subtitle
            }
        }
    }

    /// Which leaf page's *content* is currently built, independent of
    /// `trackPickerPage` — see `leafPage`'s doc comment for why this needs
    /// to be tracked separately rather than just switching on
    /// `trackPickerPage` directly.
    @State private var displayedLeafPage: TrackPickerLeaf = .audio

    /// The picker panel's current height, driving `trackPickerContent`'s
    /// outer `.frame(height:)` directly — a plain `@State` rather than a
    /// value computed reactively from `trackPickerPage` inside the view
    /// body, so it's a genuinely independent, ordinary animatable property
    /// with no `.transition`/`.animation(_:value:)` modifier anywhere near
    /// it to interact badly with (see `navigateToTrackPickerPage`'s doc
    /// comment for why that mattered enough to structure it this way).
    @State private var trackPickerHeight: CGFloat = 0

    /// The one place that changes `trackPickerPage` after the picker's
    /// initial open (`trackSelectionButton` sets the *first* page directly,
    /// before anything is on screen to animate). `displayedLeafPage` updates
    /// first, outside the animated block, and only for a real leaf — going
    /// back to `.root` leaves whatever leaf was last shown in place, so it
    /// still has real content to slide away with instead of going blank
    /// mid-exit. `trackPickerHeight` and `trackPickerPage` then change
    /// together inside the *same* `withAnimation`, so the panel's resize and
    /// `leafPage`'s slide (driven by `trackPickerPage`, via its `.offset` in
    /// `trackPickerContent`) play in sync as one motion, the same way a
    /// native `UINavigationController` push both slides the new page in and
    /// resizes its own nav bar together rather than as two separately-timed
    /// steps. Both are plain `@State` writes with nothing else watching
    /// them, unlike the `.transition`-based approaches tried before this —
    /// see `trackPickerContent`'s doc comment — so there's no ambient
    /// animation-cascading risk in combining them here.
    private func navigateToTrackPickerPage(_ page: TrackPickerPage) {
        switch page {
        case .audio: displayedLeafPage = .audio
        case .subtitle: displayedLeafPage = .subtitle
        case .root: break
        }
        withAnimation(Self.trackPickerNavigationAnimation) {
            trackPickerPage = page
            trackPickerHeight = min(estimatedHeight(for: page), Self.trackPickerMaxHeight)
        }
    }

    private var hasAudioChoice: Bool { viewModel.audioTracks.count > 1 }
    private var hasSubtitleChoice: Bool { !viewModel.subtitleTracks.isEmpty }

    /// Audio/subtitle track picker. A compact panel — not the full sheet
    /// (`TrackSelectionSheet`) this used to present, for what's really just
    /// a small in-place choice, not a task that ever warranted a dedicated
    /// screen. The root page's "Audio"/"Subtitles" rows only appear when
    /// there's an actual choice to make there: `hasAudioChoice` requires
    /// more than one audio track (a single-track asset has nothing to pick
    /// between), and `hasSubtitleChoice` requires at least one subtitle
    /// track at all. When only one of the two applies, the tap handler below
    /// skips the root page and opens straight into that one leaf — no point
    /// showing a picker whose only choice is which single row to tap. When
    /// *neither* applies — e.g. a single-audio-track asset with no
    /// subtitles — the button disables itself and dims rather than opening
    /// an empty picker.
    ///
    /// Hand-rolled overlay content (see `body`'s two `.overlay`s), not a
    /// plain `Menu`, `List`-in-`.popover`, or even a bare `.popover` (all
    /// tried first): a native `Menu`'s width/font are entirely
    /// system-controlled, which left long commentary-track titles wrapping
    /// across 3+ cramped lines with no way to widen the popup or shrink the
    /// text to compensate. Swapping that for a `List` fixed the sizing but
    /// not the legibility — `List` brings its own translucent system
    /// background that read poorly here. Moving that same content into a
    /// plain `.popover` (an explicit `.presentationBackground` in place of
    /// `List`'s) fixed *that*, but introduced a new problem: the system's
    /// own popover chrome — the arrow/rounded-rect border `UIPopoverBackgroundView`
    /// draws, independent of `.presentationBackground` — kept its own
    /// default light fill, so during the open/close transition that light
    /// chrome and this view's dark content visibly animated as two
    /// separate layers moving slightly out of step. A plain view positioned
    /// with `.overlay(alignment:)` is one single layer with one transition,
    /// so there's nothing left for it to visibly desync against.
    @ViewBuilder
    private var trackSelectionButton: some View {
        let hasAnyChoice = hasAudioChoice || hasSubtitleChoice

        Button {
            onInteract()
            if hasAudioChoice && hasSubtitleChoice {
                trackPickerPage = .root
            } else if hasAudioChoice {
                trackPickerPage = .audio
                displayedLeafPage = .audio
            } else {
                trackPickerPage = .subtitle
                displayedLeafPage = .subtitle
            }
            // Set directly (not via `navigateToTrackPickerPage`) — this is
            // the picker's very first page, appearing together with the
            // whole panel via its own open/close transition below, not a
            // drill-down with anything to slide.
            trackPickerHeight = min(estimatedHeight(for: trackPickerPage), Self.trackPickerMaxHeight)
            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = true }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.title2)
                .opacity(hasAnyChoice ? 1 : 0.4)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!hasAnyChoice)
    }

    /// A deterministic, synchronous *estimate* of a page's content height —
    /// not a real measurement. Two real `GeometryReader`+`PreferenceKey`
    /// measurement approaches were tried first (measuring the visible
    /// `ScrollView`'s own content in place, then a decoupled hidden
    /// `.fixedSize` copy of it) and *both* ended up with the panel rendering
    /// at zero size — some combination of SwiftUI's layout engine and this
    /// view's own conditionally-mounted, animated-transition, nested-in-an-
    /// `.overlay` context meant the height either never resolved away from
    /// its initial 0 or resolved to 0 outright, and nothing short of trial
    /// and error on a real device (unavailable here) was pinning down which.
    /// Row counts, by contrast, are already known synchronously
    /// (`viewModel.audioTracks.count` etc.) — computing an approximate
    /// height from those needs no measurement pass, no preference-key round
    /// trip, and so has no equivalent "stuck at zero" failure mode at all.
    /// The trade-off is precision: a title long enough to wrap onto 2 lines
    /// makes that one row taller than estimated, so the `ScrollView` below
    /// can end up very slightly short for it — but "slightly short inside a
    /// `ScrollView`" just means an extra half-line of scroll headroom, not a
    /// broken or invisible panel.
    private func estimatedHeight(for page: TrackPickerPage) -> CGFloat {
        // Root's two rows are taller than a leaf row — each carries a title
        // *and* a current-selection subtitle line (see `navigationRow`)
        // where a leaf row is normally one line (see `selectionRow`). A
        // leaf's own height also has to add its header (`leafHeaderHeight`)
        // now that header and rows move together as a single sliding unit
        // (see `leafPage`'s doc comment) rather than living outside the
        // animated area the way `.root` never needed one to.
        switch page {
        case .root:
            return Self.navigationRowHeight * 2 + Self.dividerHeight
        case .audio:
            let count = viewModel.audioTracks.count
            let rows = Self.selectionRowHeight * CGFloat(count) + Self.dividerHeight * CGFloat(max(0, count - 1))
            return Self.leafHeaderHeight + Self.dividerHeight + rows
        case .subtitle:
            // +1 for the "Off" row, which isn't in `subtitleTracks`.
            let count = viewModel.subtitleTracks.count + 1
            let rows = Self.selectionRowHeight * CGFloat(count) + Self.dividerHeight * CGFloat(max(0, count - 1))
            return Self.leafHeaderHeight + Self.dividerHeight + rows
        }
    }

    /// `navigationRow`'s two-line (title + current-selection subtitle) rows
    /// — `.padding(.vertical, 10)` (×2) plus roughly a `.subheadline` and a
    /// `.footnote` line stacked with 2pt spacing.
    private static let navigationRowHeight: CGFloat = 56
    /// `selectionRow`'s rows — `.padding(.vertical, 10)` (×2) plus a
    /// `.subheadline` title and, for most tracks, a `.footnote` metadata
    /// line underneath (see `PlaybackTrack.metadata`). Sized for that
    /// two-line case since it's the common one; a track with no flags at
    /// all renders one line shorter than estimated, same acceptable-gap
    /// trade-off as a title long enough to wrap (see `estimatedHeight(for:)`
    /// 's doc comment).
    private static let selectionRowHeight: CGFloat = 56
    /// `backRow`/`leafTitleRow`'s own height — `.padding(.vertical, 12)`
    /// (×2) plus roughly one `.subheadline` line.
    private static let leafHeaderHeight: CGFloat = 44
    private static let dividerHeight: CGFloat = 1

    /// The root page — "Audio"/"Subtitles" navigation rows. Always mounted,
    /// at its own fixed height, regardless of `trackPickerPage` — see
    /// `trackPickerContent`'s doc comment for why this is structured as an
    /// always-present base layer rather than one case of a `switch` that
    /// swaps in and out.
    private var rootPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                navigationRow(
                    systemImage: "waveform", title: String(localized: "Audio"), value: currentAudioTrackTitle
                ) { navigateToTrackPickerPage(.audio) }
                divider
                navigationRow(
                    systemImage: "captions.bubble", title: String(localized: "Subtitles"), value: currentSubtitleTrackTitle
                ) { navigateToTrackPickerPage(.subtitle) }
            }
        }
        .frame(height: estimatedHeight(for: .root))
    }

    /// Slides `leafPage` fully clear of the panel's own bounds when parked
    /// off-screen — bigger than `trackPickerMaxWidth` on purpose, so it's
    /// unambiguously outside the panel regardless of which width between
    /// `trackPickerIdealWidth` and `trackPickerMaxWidth` actually gets used.
    private static let trackPickerSlideOffset: CGFloat = 400

    /// A leaf page (`.audio`/`.subtitle`) for whichever page
    /// `displayedLeafPage` currently names — *not* `trackPickerPage`
    /// directly, and always mounted (not conditionally, the way an earlier
    /// version of this did with `if trackPickerPage != .root`) — see
    /// `trackPickerContent`'s doc comment for why. Its own back/title header
    /// (`backRow`/`leafTitleRow`) is stacked *inside* this same view,
    /// directly above its track list, so both move together as one unit
    /// when the whole thing slides — a separate, independently cross-fading
    /// header was part of what made an earlier version of this read as "a
    /// strong fade" rather than a clean slide.
    private var leafPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasAudioChoice && hasSubtitleChoice {
                backRow(for: displayedLeafPage)
            } else {
                leafTitleRow(for: displayedLeafPage)
            }
            divider

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch displayedLeafPage {
                    case .audio:
                        trackRows(viewModel.audioTracks) { track in
                            onInteract()
                            viewModel.selectAudioTrack(id: track.id)
                            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                        }

                    case .subtitle:
                        selectionRow(
                            title: String(localized: "Off"),
                            metadata: nil,
                            isSelected: !viewModel.subtitleTracks.contains { $0.isSelected }
                        ) {
                            onInteract()
                            viewModel.selectSubtitleTrack(id: nil)
                            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                        }
                        if !viewModel.subtitleTracks.isEmpty { divider }
                        trackRows(viewModel.subtitleTracks) { track in
                            onInteract()
                            viewModel.selectSubtitleTrack(id: track.id)
                            withAnimation(Self.trackPickerAnimation) { isShowingTrackPicker = false }
                        }
                    }
                }
            }
        }
        .frame(height: min(estimatedHeight(for: displayedLeafPage.page), Self.trackPickerMaxHeight))
        // Opaque, matching the panel's own fill — without this, both this
        // leaf and `rootPage` underneath are transparent apart from their
        // own text/icons, so root's rows would show through wherever this
        // leaf's rows don't happen to cover the exact same pixels mid-slide.
        .background(Color(white: 0.1))
    }

    /// The picker's actual content: `rootPage` as a permanent base layer,
    /// with `leafPage` layered on top, always mounted but pushed off to
    /// `trackPickerSlideOffset` (invisible, clipped by the panel's own
    /// bounds) while `trackPickerPage == .root`, animated back to `0` (
    /// covering root) otherwise. Two things were tried and abandoned before
    /// landing on plain `.offset` + `withAnimation`:
    ///
    /// 1. A single view whose *content* swapped via `.id()` + `.transition`.
    ///    The outgoing and incoming view necessarily animate together as a
    ///    matched pair with no independent "this one stays still" option,
    ///    which read as a cross-dissolve rather than a page landing on top
    ///    of a stationary one (reported as "a strong fade").
    /// 2. Two independent views (`rootPage` + a conditionally-mounted
    ///    `leafPage`) with the leaf's *insertion/removal* carrying a
    ///    `.transition(.move(edge:))`. Correct in principle, but disabling
    ///    the *container's* height animation via `.animation(nil, value:)`
    ///    turned out to cascade down as the ambient transaction for
    ///    everything inside it too, silently killing the leaf's own
    ///    `.transition` right along with it (reported as no animation at
    ///    all, just an instant swap) — and an explicit override
    ///    (`.animation(_:value:)` back on the leaf) didn't reliably survive
    ///    contact with `.transition`'s own insert/remove machinery either.
    ///
    /// Plain `.offset(x:)` sidesteps both: it's not `.transition` at all, so
    /// there's no insert/remove pairing and no ambient-animation cascading
    /// to fight. `trackPickerHeight` below is an ordinary `@State` `CGFloat`
    /// with nothing else watching it, changed in the same `withAnimation` as
    /// `trackPickerPage` (see `navigateToTrackPickerPage`) — so the resize
    /// and the slide play as one synchronized motion rather than the panel
    /// growing/shrinking independently of the page moving across it.
    @ViewBuilder
    private var trackPickerContent: some View {
        ZStack(alignment: .topLeading) {
            rootPage

            leafPage
                .offset(x: trackPickerPage == .root ? Self.trackPickerSlideOffset : 0)
                // Belt-and-suspenders alongside the panel's own `.clipped()`
                // below — without this, the leaf parked off-screen could
                // still intercept taps meant for `rootPage` underneath it.
                .allowsHitTesting(trackPickerPage != .root)
        }
        .frame(idealWidth: Self.trackPickerIdealWidth, maxWidth: Self.trackPickerMaxWidth)
        .frame(height: trackPickerHeight, alignment: .top)
        .clipped()
        .foregroundStyle(.white)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    private func backRow(for page: TrackPickerLeaf) -> some View {
        Button {
            navigateToTrackPickerPage(.root)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text(page == .audio ? String(localized: "Audio") : String(localized: "Subtitles"))
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.ignore`, not `.combine` — the leading chevron is purely
        // decorative wayfinding, not information VoiceOver should read on
        // its own; the plain "Back" label already conveys what this button
        // does regardless of which leaf it's read from.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Back"))
    }

    private func leafTitleRow(for page: TrackPickerLeaf) -> some View {
        Text(page == .audio ? String(localized: "Audio") : String(localized: "Subtitles"))
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    /// A root-page row that drills into a leaf page rather than selecting
    /// anything itself — its trailing chevron (vs. a leaf row's checkmark)
    /// is what signals that, and `value` previews the leaf's current
    /// selection so it's visible without the extra tap. `systemImage`
    /// (`"waveform"` for Audio, `"captions.bubble"` for Subtitles — the
    /// latter shared with `trackSelectionButton`'s own icon deliberately,
    /// since it's Apple's canonical captions/subtitles glyph) gives the two
    /// rows the same "leading icon, title, chevron" shape as a native
    /// Settings row.
    private func navigationRow(
        systemImage: String, title: String, value: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline)
                    Text(value)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.ignore` — the leading icon and trailing chevron are decorative;
        // `value` (the current selection, e.g. "Default"/"Off") is folded
        // into the label since there's no separate `.accessibilityValue`
        // reader for a row that navigates rather than adjusts in place.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(title), \(value)"))
    }

    /// A leaf-page row's list of tracks, dividers interleaved between
    /// entries (not after the last) — the same separator `List` would draw
    /// for free, hand-rolled here since this view doesn't use `List` (see
    /// `trackSelectionButton`'s doc comment for why).
    @ViewBuilder
    private func trackRows(_ tracks: [PlaybackTrack], onSelect: @escaping (PlaybackTrack) -> Void) -> some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            if index > 0 { divider }
            selectionRow(title: track.title, metadata: track.metadata, isSelected: track.isSelected) {
                onSelect(track)
            }
        }
    }

    /// `metadata` (Default/Forced/Hearing Impaired/Commentary/External, see
    /// `AetherPlaybackEngine.metadataLabel(for:)`) renders as a second,
    /// `.footnote`-styled line under `title` when present — same "title +
    /// secondary line" shape as `navigationRow` above, just with a
    /// selection checkmark leading instead of a chevron trailing. `nil`
    /// collapses back to a single line rather than leaving an empty gap.
    private func selectionRow(title: String, metadata: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                // Reserves the checkmark's width whether selected or not
                // (`.opacity` rather than an `if`) so the title doesn't
                // shift left/right as selection changes between rows.
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                    if let metadata {
                        Text(metadata)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.ignore` — the checkmark is purely visual state (`.opacity`, not
        // an `if`, so it's always present in the tree either way); the
        // *actual* selected state a VoiceOver user needs is exposed via
        // `.isSelected` below instead, not left to a shape/opacity a screen
        // reader can't perceive at all.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metadata.map { String(localized: "\(title), \($0)") } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var divider: some View {
        Divider().overlay(Color.white.opacity(0.15))
    }

    private var currentAudioTrackTitle: String {
        viewModel.audioTracks.first(where: \.isSelected)?.title ?? String(localized: "Default")
    }

    private var currentSubtitleTrackTitle: String {
        viewModel.subtitleTracks.first(where: \.isSelected)?.title ?? String(localized: "Off")
    }

    /// The rewind/play-pause/forward row — swapped for a centered spinner
    /// while `isBuffering`, rather than leaving the play/pause button
    /// showing a state that isn't actually available yet (tapping play
    /// mid-buffer did nothing perceptible, which read as broken rather than
    /// "in progress"). Covers `.idle` (still fetching the item/playback
    /// info/stream URL over the network — `PlayerViewModel.state` stays
    /// `.idle` for that entire window, since nothing updates it until
    /// `engine.load(url:)` is actually reached; without this the transport
    /// row showed a plain, tappable-looking Play button with no indication
    /// anything was happening — confirmed live, 2026-08-24, most visibly
    /// while offline, where that window can run long enough to be mistaken
    /// for a dead screen), the initial buffer on load/resume (`.loading`),
    /// an in-progress scrub (`.seeking`), an ordinary mid-playback rebuffer
    /// (`.buffering`), and a dropped/retrying source connection
    /// (`.reconnecting` — labeled distinctly below, rather than reading as
    /// an unexplained generic stall).
    @ViewBuilder
    private var transportControls: some View {
        if isBuffering {
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.6)
                if viewModel.state == .reconnecting {
                    Text("Reconnecting…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            // Matches the play/pause button's own `.font(.system(size:
            // 44))` footprint, so nothing else in the layout shifts
            // when this swaps in and out.
            .frame(height: 44)
        } else {
            HStack(spacing: 40) {
                Button {
                    onInteract()
                    viewModel.seek(to: max(0, displayedTime - 15))
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title)
                        // Same HIG-44pt tap-target padding as every other
                        // icon button in this overlay — see the close
                        // button's doc comment in `topSection`.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Rewind 15 Seconds"))

                Button {
                    onInteract()
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 44))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(viewModel.state == .playing ? String(localized: "Pause") : String(localized: "Play"))

                Button {
                    onInteract()
                    viewModel.seek(to: min(viewModel.duration, displayedTime + 30))
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Fast Forward 30 Seconds"))
            }
            .foregroundStyle(.white)
        }
    }

    private var isBuffering: Bool {
        viewModel.state == .idle || viewModel.state == .loading || viewModel.state == .seeking
            || viewModel.state == .buffering || viewModel.state == .reconnecting
    }

    /// Logo preferred, pinned top-left — the same "logo over text-title
    /// fallback" convention `BackdropLogoOverlay` uses on the detail pages.
    /// Falls back to the plain title text when the item has no logo image at
    /// all, or when `LogoImageView` fails to load the one it has (a 404, a
    /// timeout after retries — see that type's doc comment). Contrast
    /// against the video behind it comes from the overlay's own background
    /// gradient (see `topSection`'s doc comment), not from anything owned
    /// here.
    ///
    /// For episodes, an "S1:E4 · Episode Name" line (`MediaItem.railSubtitle`
    /// — falls back to just the episode name if the numbering isn't present)
    /// always appears below whatever's on the first line, so the episode
    /// itself stays identifiable even when the logo/title above it only
    /// names the show. What's on that first line still follows the
    /// logo-preferred rule above: the show's logo when there is one, or —
    /// only for episodes, since a movie/series' own title already *is* the
    /// name that would go here — the show's plain title text when there
    /// isn't.
    @ViewBuilder
    private var titleRow: some View {
        if let item = viewModel.item {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let logoURL = item.logoImageURL {
                        LogoImageView(url: logoURL, fallback: titleText(item.railTitle))
                            .frame(maxWidth: 240, maxHeight: 60, alignment: .leading)
                    } else if item.kind == .episode {
                        titleText(item.railTitle)
                    } else {
                        titleText(item.name)
                    }

                    if item.kind == .episode, let episodeSubtitle = item.railSubtitle {
                        episodeSubtitleText(episodeSubtitle)
                    }
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private func titleText(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func episodeSubtitleText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
    }

    /// Progress track with its timestamps at either end, rather than on
    /// their own row below it. The trailing timestamp doubles as a button —
    /// see `showRemainingTime`.
    private var scrubberBar: some View {
        VStack(spacing: 4) {
            if let format = viewModel.videoFormatDescription {
                Text(format)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }

            // `spacing: 16`, not the tighter 8 this used to be — the thumb
            // is a 20pt circle straddling the track's own edge (see
            // `scrubberTrack`'s doc comment), so it overflows a few points
            // past the track's declared bounds at either extreme. 8pt of
            // clearance wasn't enough room for that overflow to clear the
            // timestamp text next to it, so the thumb visibly overlapped
            // "0:05"/the end time whenever it sat at either end of the bar.
            // Applied here (once, symmetrically) rather than as one-sided
            // padding on `scrubberTrack` itself, so both ends keep equal
            // spacing.
            HStack(spacing: 16) {
                // Both labels reserve space for the widest string
                // `formatTime`/`endTimeText` can ever produce (an invisible
                // `"-9:59:59"`/`"9:59:59"` reference inside a `ZStack`,
                // rather than a hardcoded point width, so this still tracks
                // Dynamic Type) — without this, crossing an hour/minute
                // digit-count boundary (e.g. the countdown ticking from
                // "-1:00:00" to "-59:59") changed each label's natural
                // width, which pushed `scrubberTrack`'s own bounds around
                // with it. Each label is aligned toward the scrubber (the
                // leading one trailing-aligned, the trailing one
                // leading-aligned) so its digits grow away from the track
                // rather than shifting it. Fixing the track's own width
                // this way is also what keeps `ScrubThumbnailPreview`'s
                // drag-to-x-offset math stable while scrubbing.
                ZStack(alignment: .trailing) {
                    Text("9:59:59").monospacedDigit().hidden()
                    Text(Self.formatTime(displayedTime)).monospacedDigit()
                }

                scrubberTrack

                Button {
                    showRemainingTime.toggle()
                } label: {
                    ZStack(alignment: .leading) {
                        Text("-9:59:59").monospacedDigit().hidden()
                        Text(endTimeText).monospacedDigit()
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding()
    }

    /// A hand-drawn track rather than a plain `Slider` — SwiftUI's `Slider`
    /// only lets `.tint()` style the *elapsed* (filled) portion; the
    /// *remaining* (unfilled) portion always renders in the system's own
    /// low-opacity gray regardless of tint, which read as barely-there
    /// against a dark video frame. Drawing both segments directly gives
    /// control over the remaining segment's color too — `.opacity(0.35)`
    /// here vs. full white for elapsed, a deliberate step up from the
    /// system default rather than another background layer behind the
    /// whole bar.
    private var scrubberTrack: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = viewModel.duration > 0 ? min(1, max(0, displayedTime / viewModel.duration)) : 0

            ZStack(alignment: .leading) {
                // Both segments get their own explicit `height: 4` directly
                // — rather than relying on a `.frame(height: 4)` up on the
                // enclosing `ZStack` to propose that size down to them —
                // specifically so the 20pt thumb `Circle` below can't drag
                // the whole track taller with it. A shared parent frame
                // sizes to fit its *largest* child before the frame value
                // is applied to the children individually; pinning each
                // shape's own size is unambiguous regardless.
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.white)
                    .frame(width: width * fraction, height: 4)

                // Deliberately much larger than the 4pt track it sits on
                // top of — a native `Slider`'s thumb is the same way, a
                // sizable circle overlapping a thin line, rather than
                // matching the track's own thickness. Matters more here
                // than it would on a mouse-driven UI: on a real device this
                // is the actual finger touch target. The shadow (rather
                // than, say, a stroke) is what actually separates it from
                // the elapsed segment visually — both are solid white, so
                // without it the thumb only read as the track's leading
                // end looking slightly fatter, not as a distinct handle.
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: width * fraction - 10)
            }
            .frame(maxHeight: .infinity)
            // `.overlay`, not a 4th `ZStack` sibling above — a `ZStack`
            // sizes itself to its *largest* child (see the Capsules' own
            // doc comment just above for the same lesson learned the hard
            // way about the 20pt thumb), so the bubble's own much taller
            // natural size (~114pt: 90pt image + spacing + the timestamp
            // pill) was inflating this whole track's reported height even
            // though `.offset` only moves where it *renders* — confirmed
            // live (2026-08-17): the scrubber row visibly dropped every
            // time a drag started. An `.overlay` is layout-inert by
            // definition — its content can never affect the base view's
            // own reported size, however tall it is — so this is the
            // correct tool here, not just a workaround.
            .overlay(alignment: .leading) {
                // Gated on `isDraggingScrubber`, not `isScrubbing` — the
                // latter deliberately stays `true` past finger-lift while a
                // seek lands (see that property's own doc comment above),
                // which would otherwise leave a stale bubble hanging on
                // screen after the finger's already gone. Clamped so its
                // own 160pt width stays fully inside the track even when
                // dragging to either extreme — unlike the 20pt thumb above,
                // it would otherwise clip off-screen there.
                if isDraggingScrubber, viewModel.supportsScrubThumbnails {
                    ScrubThumbnailPreview(image: scrubThumbnailImage, timeText: Self.formatTime(scrubTime))
                        .offset(
                            x: min(
                                max(width * fraction - ScrubThumbnailPreview.width / 2, 0),
                                width - ScrubThumbnailPreview.width
                            ),
                            // Clears both the thumb and a finger actually
                            // touching it — `.overlay(alignment: .leading)`
                            // keeps the same vertically-centered-on-the-
                            // track baseline the old `ZStack(alignment:
                            // .leading)` gave it, so this offset needs no
                            // change from what that vertical centering
                            // already required: roughly half the bubble's
                            // own height plus the thumb's half-height.
                            y: -90
                        )
                }
            }
            // The visible track is a thin 4pt line, but the drag target
            // spans this whole `GeometryReader` frame (see `.frame(height:
            // 44)` below) — matches a plain `Slider`'s actual tap target,
            // which is much taller than what it visually draws.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        // Every move resets `PlayerView`'s auto-hide
                        // countdown — without this, a long, slow drag could
                        // outlast the 3-second timer and have the controls
                        // (scrubber included, mid-touch) fade out from under
                        // the user's finger.
                        onInteract()
                        isDraggingScrubber = true
                        isScrubbing = true
                        let newFraction = min(1, max(0, drag.location.x / width))
                        scrubTime = newFraction * viewModel.duration
                        requestScrubThumbnail(at: scrubTime)
                    }
                    .onEnded { _ in
                        // `isScrubbing` deliberately stays `true` here — see
                        // the `onChange`s below for why, and `displayedTime`'s
                        // doc comment for what this keeps showing in the
                        // meantime.
                        onInteract()
                        isDraggingScrubber = false
                        scrubThumbnailTask?.cancel()
                        viewModel.seek(to: scrubTime)
                    }
            )
        }
        .frame(height: 44)
        // A plain `Slider` gets VoiceOver adjustability for free; this
        // hand-rolled replacement needs it spelled out explicitly so
        // scrubbing isn't a regression for VoiceOver users.
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(Self.formatTime(displayedTime)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: viewModel.seek(to: min(viewModel.duration, displayedTime + 15))
            case .decrement: viewModel.seek(to: max(0, displayedTime - 15))
            @unknown default: break
            }
        }
        // `viewModel.seek(to:)` is async — the engine reports its own
        // `.seeking` state and only pushes the new `currentTime` once the
        // seek actually lands, both some time after `onEnded` fires above.
        // Clearing `isScrubbing` synchronously in `onEnded` (the original
        // approach) made `displayedTime` fall back to `viewModel.currentTime`
        // immediately — still the *pre-seek* position for that gap — so the
        // thumb visibly snapped back to where playback had been before
        // jumping forward again once the real update arrived. Keeping
        // `isScrubbing` on through that gap keeps the thumb pinned exactly
        // where the user left it; these two `onChange`s are what eventually
        // let go of it again, once there's real evidence the seek landed
        // rather than on a fixed timer that could fire too early or too late.
        //
        // Two independent signals, either sufficient on its own, since
        // neither is individually guaranteed: a very small seek might never
        // visibly enter `.seeking` before the matching time update arrives
        // (the state-based check would never fire), while a target that
        // lands exactly between two clock ticks could in principle skip past
        // the epsilon window given engine-side rounding (the time-based
        // check would never fire). `!isDraggingScrubber` on both guards
        // against a stray match landing mid-drag, before `onEnded` has even
        // issued the seek this is meant to be watching for.
        .onChange(of: viewModel.currentTime) { _, newTime in
            guard isScrubbing, !isDraggingScrubber else { return }
            if abs(newTime - scrubTime) < 1.0 {
                isScrubbing = false
            }
        }
        .onChange(of: viewModel.state) { oldState, newState in
            guard isScrubbing, !isDraggingScrubber else { return }
            if oldState == .seeking, newState != .seeking {
                isScrubbing = false
            }
        }
        // SwiftUI only auto-cancels a `.task { }`-modifier Task on
        // disappearance, not a plain `Task` stored in `@State` like
        // `scrubThumbnailTask` — without this, closing the player mid-drag
        // (before a throttled fetch has fired) would leave that fetch/crop
        // running to completion against a state box nobody can ever render
        // from again. Harmless (no crash), just wasted network/CPU work
        // with no observer left.
        .onDisappear {
            scrubThumbnailTask?.cancel()
        }
    }

    /// How often `requestScrubThumbnail(at:)` allows a fetch to actually
    /// fire during a continuous drag.
    private static let scrubThumbnailThrottleInterval: TimeInterval = 0.12

    /// Throttled scrub-thumbnail fetch, called from every `scrubberTrack`
    /// drag tick. Deliberately a *throttle*, not a debounce (the shape this
    /// replaced, matching `SearchViewModel`'s search-as-you-type debounce):
    /// a debounce only fires once input goes quiet, which for a scrubber
    /// drag means a sufficiently fast, sustained, continuous gesture could
    /// in principle never let it fire at all until the finger actually
    /// pauses. A throttle instead guarantees a fetch roughly every
    /// `scrubThumbnailThrottleInterval` throughout continuous movement:
    /// fires immediately if that long has already passed since the last
    /// fetch *started* (not since the last tick — this is wall-clock time
    /// via `lastScrubThumbnailFireDate`, unrelated to how often
    /// `.onChanged` itself fires), otherwise schedules exactly one trailing
    /// fetch for whenever the window is up. Every tick in between just
    /// updates `pendingScrubSeconds`, which that already-scheduled fetch
    /// reads when it actually runs — so a whole burst of ticks collapses
    /// into a single fetch at the drag's *latest* position, not a stale
    /// one from partway through the burst.
    ///
    /// No-ops when `supportsScrubThumbnails` is false, matching
    /// `scrubberTrack`'s own gate on rendering the bubble at all.
    private func requestScrubThumbnail(at seconds: TimeInterval) {
        guard viewModel.supportsScrubThumbnails else { return }
        pendingScrubSeconds = seconds
        guard scrubThumbnailTask == nil else { return }

        let elapsed = lastScrubThumbnailFireDate.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let delay = max(0, Self.scrubThumbnailThrottleInterval - elapsed)
        scrubThumbnailTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else {
                scrubThumbnailTask = nil
                return
            }
            lastScrubThumbnailFireDate = Date()
            let requested = pendingScrubSeconds ?? seconds
            let image = await viewModel.scrubThumbnail(atSeconds: requested)
            // `nil` means "not available yet", not "no thumbnail exists" —
            // see `TrickplayThumbnailProvider`'s doc comment — so only a
            // successful result overwrites what's already showing.
            if !Task.isCancelled, let image {
                scrubThumbnailImage = image
            }
            scrubThumbnailTask = nil
        }
    }

    /// The scrubber's trailing timestamp — the asset's total duration by
    /// default, or a countdown to the end once `showRemainingTime` is
    /// toggled on. Reads off `displayedTime` (the scrub-in-progress position
    /// while dragging, otherwise live playback position — see
    /// `displayedTime`), so the countdown keeps counting down as the user
    /// scrubs, not just during normal playback.
    private var endTimeText: String {
        guard showRemainingTime else { return Self.formatTime(viewModel.duration) }
        return "-" + Self.formatTime(max(0, viewModel.duration - displayedTime))
    }

    /// The scrub-in-progress position while `isScrubbing`, otherwise live
    /// playback position. `isScrubbing` now covers more than the drag touch
    /// itself — it stays on through the just-issued seek landing too (see
    /// `scrubberTrack`'s gesture/`onChange`s) — so this keeps reading
    /// `scrubTime` for that whole window, not just while a finger is down.
    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : viewModel.currentTime
    }

    private static func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
