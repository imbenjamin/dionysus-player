import SwiftUI

/// A backdrop image with a logo (or title text fallback) overlaid at the
/// bottom, Disney+-style. Fills whatever frame its caller gives it —
/// callers own sizing and any safe-area handling, since those differ
/// between call sites (a fixed-height detail-page header that clears the
/// status bar vs. a hero rail's per-page card with no such inset).
///
/// Shared between `HeroHeaderView` (asset detail pages) and `HeroRailCard`
/// (Home's hero rail) rather than duplicated — the visual composition is
/// identical, only the surrounding frame/padding differs.
///
/// `enable3DDepth`, plus `tiltX`/`tiltY` (each roughly `-1...1`, from
/// `DeviceTiltObserver`) drive an optional device-tilt 3D depth effect: the
/// backdrop is pushed *behind* the screen plane via `.rotation3DEffect`'s
/// `anchorZ`/`perspective` (rotates around a pivot deep in Z, like the back
/// wall of a diorama) and the logo is pulled *in front* of it (rotates
/// around a pivot closer to the viewer, plus a shadow it casts onto the
/// backdrop below), so tilting the device reads as looking into a recessed
/// scene with the logo genuinely hovering above its surface. An earlier
/// version instead offset the two layers sideways by different amounts
/// (classic 2D parallax) — it read as flat and arbitrary rather than
/// physically grounded, per direct feedback trying it on a real device;
/// this 3D-rotation approach replaced it entirely.
///
/// All default to off/`0` (identical to this view's pre-effect rendering)
/// — only `HeroHeaderView` opts in; `HeroRailCard`'s auto-advancing
/// carousel doesn't, since a constantly-moving background there would
/// fight the slide transition rather than complement it.
struct BackdropLogoOverlay: View {
    /// The backdrop image to show — a live item's own network URL, or an
    /// offline download's local file URL (`DownloadFileStore
    /// .url(forRelativePath:)`); `AdaptiveArtworkImage` below picks the
    /// right rendering path from `url.isFileURL` alone, so callers don't
    /// need to say which kind of item they have. Plain values rather than
    /// a `MediaItem`, so `DownloadedAssetDetailView`'s offline hero header
    /// can reuse this same effect from its own local artwork.
    let backdropURL: URL?
    /// `nil` falls back to `titleText` — same as a live item with no logo
    /// image of its own.
    let logoURL: URL?
    /// The show/movie/collection's own name — the no-logo fallback's first
    /// (only, for non-episode content) line.
    let title: String
    /// Drives the backdrop's placeholder glyph (`MediaPlaceholderBox`, via
    /// `AdaptiveArtworkImage`) while it's loading or has failed — `nil`
    /// (the default) falls back to a generic glyph, needed since
    /// `DownloadedAssetDetailView`'s offline hero has no live
    /// `BaseItemKind` to pass (only a `DownloadedItemKind`).
    var kind: BaseItemKind? = nil
    /// Non-`nil` only for episode content — the specific episode's own
    /// title, shown as a second line under whichever of the logo/`title`
    /// rendered above it: under the logo image when there is one, or
    /// under `title` as a second line when there isn't.
    var episodeTitle: String? = nil
    /// Spoken-only season/episode marker ("season 19 episode 6"), inserted
    /// into the accessibility label between `title` and `episodeTitle` —
    /// see `accessibilityLabelText`. Confirmed via direct feedback that
    /// VoiceOver reading "Top Gear, Africa Special" alone (the visual
    /// content — a show title, then an episode title, no number between
    /// them) didn't make clear *which* episode; never shown visually, the
    /// hero's own on-screen content is unchanged.
    var episodeNumberAccessibilityText: String? = nil
    /// `.leading` (Disney+-style, unchanged) for `HeroRailCard`'s hero rail
    /// cards; `HeroHeaderView` (every detail-page hero) passes `.center`
    /// instead — a left-aligned logo/episode-title stack reads as lopsided
    /// whenever the two lines are noticeably different widths, which
    /// centering fixes regardless of either element's own width.
    var alignment: HorizontalAlignment = .leading
    /// Whether to reserve the extra backdrop headroom (`backdropScale`)
    /// the effect needs to never uncover an image edge — kept as its own
    /// flag rather than inferred from `tiltX`/`tiltY` being nonzero, so the
    /// backdrop's framing doesn't subtly shift the moment
    /// `DeviceTiltObserver` reports its very first nonzero sample.
    var enable3DDepth: Bool = false
    var tiltX: CGFloat = 0
    var tiltY: CGFloat = 0
    /// How far the *accessibility* frame should be inset from the top,
    /// separately from the *visual* content, which keeps bleeding all the
    /// way to the physical top edge regardless of this value — see `body`'s
    /// own doc comment on why the two need to differ at all. `0` (the
    /// default) matches this view's behavior before that fix existed;
    /// `HeroHeaderView` is the one caller that passes its own
    /// `statusBarInset` instead.
    var accessibilityTopInset: CGFloat = 0

    /// The backdrop's rotation at full tilt, and how far behind the screen
    /// plane it pivots (`anchorZ`, in points — negative pushes it away from
    /// the viewer). Together with `perspective` these are what make tilting
    /// the device read as looking into a receded scene rather than sliding
    /// an image sideways.
    ///
    /// These three numbers interact in ways that aren't obvious from the
    /// API alone — worth recording exactly how this landed here since it
    /// took several real-device-informed passes: `12°`/`-180`/`0.35` (the
    /// first attempt) was too subtle to read as 3D at all. Isolating
    /// `.rotation3DEffect` with an exaggerated fixed test (`45°`/`-180`/
    /// `0.3`) confirmed the modifier itself renders a clearly dramatic
    /// result at those settings — so the *first* attempt's problem was the
    /// specific numbers, not the technique. But naively scaling all three
    /// down together (`22°`/`-220`/`0.25`) produced *no visible rotation at
    /// all*, despite `-220`/`0.25` each individually looking like "more
    /// dramatic" versions of `-180`/`0.3` — `anchorZ` and `perspective`
    /// clearly interact multiplicatively rather than each mattering in
    /// isolation, and pushing both further in the "more dramatic" direction
    /// at once overshot into some degenerate combination instead. The fix
    /// was to stop varying all three at once: keep the *confirmed-visible*
    /// `-180`/`0.3` pairing fixed, and only tune the angle within it —
    /// landed on `30°` there, then halved to `15°` after real-device
    /// feedback that the effect read as too dramatic at `30°`.
    private static let backdropMaxRotationDegrees: Double = 15
    private static let backdropAnchorZ: CGFloat = -180
    private static let backdropPerspective: CGFloat = 0.3
    /// Headroom for the backdrop's rotation to reveal without uncovering an
    /// edge — true 3D rotation swings the image's rendered corners further
    /// than a flat offset would, so this needs more slack than a simple
    /// translate. Brought down from `1.5` alongside `backdropMaxRotationDegrees`
    /// halving — less rotation swings the corners less, so less reserved
    /// headroom is needed to still never reveal an edge.
    private static let backdropScale: CGFloat = 1.25

    /// The logo's own rotation is gentler than the backdrop's — it's the
    /// "near" plane, close enough to the viewer that it shouldn't swing as
    /// dramatically, and a brand logo/wordmark warping much at all reads as
    /// broken rather than 3D. `anchorZ` is positive (pivots *in front of*
    /// the screen plane, toward the viewer) — the opposite sign from the
    /// backdrop's, which is what actually separates the two into "behind
    /// the glass" vs. "floating above it" instead of both just tilting the
    /// same way.
    private static let logoMaxRotationDegrees: Double = 5
    private static let logoAnchorZ: CGFloat = 150
    private static let logoPerspective: CGFloat = 0.4
    /// A shadow cast "down" onto the backdrop is the other half of selling
    /// "floating above the surface" — shifts opposite the logo's own tilt
    /// direction (a light source overhead stays fixed while the logo's
    /// implied height above the backdrop changes the shadow's spread) and
    /// is present even at rest (`enable3DDepth` alone, not tilt magnitude,
    /// gates its opacity below), since a stationary floating object still
    /// casts a shadow.
    private static let logoShadowRange: CGFloat = 7

    /// Two layers, not one: `visualContent`'s own frame bleeds all the way
    /// to the physical top edge (see `HeroHeaderView`'s doc comment on
    /// `.ignoresSafeArea(edges: .top)`), which is purely a rendering choice
    /// for the full-bleed look — but an *accessibility* element sharing that
    /// same frame turned out to matter too: confirmed live (VoiceOver, real
    /// device) that whenever this element's frame overlapped the status
    /// bar's own screen region, VoiceOver's reading of it pulled in
    /// unrelated content alongside the real label — a clock-shaped number
    /// and a varying system-icon-shaped word, framed by an iOS "content
    /// changed" tone, regardless of exactly where within the (single,
    /// confirmed-via-VoiceOver's-own-focus-outline) element you tapped.
    /// Reproduced regardless of Screen Recognition/Image Descriptions (both
    /// off), artwork content (plain, non-stylized posters included), and
    /// load timing (still happened well after the page had fully settled)
    /// — ruling out image-content OCR, load-timing races, and anything this
    /// view's own label/traits control directly, before landing on the
    /// status-bar-overlap explanation below. Splitting the accessibility
    /// element out into its own layer, inset from the top by
    /// `accessibilityTopInset` so its frame never reaches the status bar at
    /// all, is the fix — confirmed live. `visualContent` keeps bleeding to
    /// the edge exactly as before; only the *accessible* element's bounds
    /// change.
    var body: some View {
        ZStack {
            visualContent
                .accessibilityHidden(true)

            // Purely for accessibility — no visual content of its own, and
            // no `.contentShape` needed either: `Color`'s own hit region
            // already matches its laid-out frame, unlike the aspect-filled
            // image `visualContent` needs one for (see that property's own
            // comment). `accessibilityTopInset` is what keeps this from
            // ever overlapping the status bar; see this type's own doc
            // comment.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, accessibilityTopInset)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabelText)
        }
    }

    private var visualContent: some View {
        // The backdrop drives its own width via `.aspectRatio(.fill)` and
        // would otherwise blow out the layout — a `VStack` sizes itself to
        // its widest child, so an unconstrained image here would make the
        // *entire* containing page that wide.
        //
        // Constrained via a `Color.clear` placeholder sized by `.frame(
        // maxWidth: .infinity)` (which, unlike the aspect-filled image
        // itself, has no oversized ideal-width opinion to override) with the
        // actual image as its `.background` — backgrounds size themselves to
        // match their container, not the other way around, so the image
        // ends up correctly constrained without needing to read a proxy
        // size at all. Deliberately not `GeometryReader` (an earlier version
        // of this used one) — simpler, and avoids an extra layout pass.
        // This also used to be `.containerRelativeFrame(.horizontal)`,
        // which resolves the width problem in principle but in practice got
        // stuck reporting a stale (too-wide) size after rotating portrait →
        // landscape → portrait, overflowing the screen on the way back.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                AdaptiveArtworkImage(url: backdropURL, placeholderSystemImage: kind?.placeholderSystemImage ?? "photo")
                    .scaleEffect(enable3DDepth ? Self.backdropScale : 1)
                    .rotation3DEffect(
                        tiltRotation.angle, axis: tiltRotation.axis,
                        anchor: .center, anchorZ: Self.backdropAnchorZ, perspective: Self.backdropPerspective
                    )
            }
            .clipped()
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: Alignment(horizontal: alignment, vertical: .bottom)) {
                // A single `VStack` rather than the logo/title alone —
                // `episodeTitle`, when present, stacks as its own line
                // below whichever identity element rendered above it,
                // rotating/casting shadow together with it as one unit
                // rather than needing its own separate 3D treatment.
                VStack(alignment: alignment, spacing: 4) {
                    Group {
                        if let logoURL {
                            // `LogoImageView`'s fade-in is worth it for a
                            // network fetch that can take a moment; a local
                            // file read (`LocalFileImage`) is synchronous
                            // and already cached, so there's no load
                            // latency for a fade to hide — rendering it
                            // plainly instead.
                            if logoURL.isFileURL {
                                LocalFileImage(url: logoURL, contentMode: .fit)
                                    .frame(maxWidth: 240, maxHeight: 80, alignment: Alignment(horizontal: alignment, vertical: .center))
                            } else {
                                LogoImageView(url: logoURL, fallback: titleText, retryPatience: .extended)
                                    .frame(maxWidth: 240, maxHeight: 80, alignment: Alignment(horizontal: alignment, vertical: .center))
                            }
                        } else {
                            titleText
                        }
                    }

                    if let episodeTitle {
                        Text(episodeTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(textAlignment)
                    }
                }
                .padding()
                .rotation3DEffect(
                    logoRotation.angle, axis: logoRotation.axis,
                    anchor: .center, anchorZ: Self.logoAnchorZ, perspective: Self.logoPerspective
                )
                .shadow(
                    color: .black.opacity(enable3DDepth ? 0.45 : 0), radius: 10,
                    x: -tiltX * Self.logoShadowRange, y: -tiltY * Self.logoShadowRange * 0.5 + 4
                )
            }
            // Root-causes a live-reproduced bug (2026-08-18): "the hero rail
            // item is hard to tap; right-hand taps register as the *next*
            // item instead." `AsyncRemoteImage`'s backdrop is `.resizable()
            // .aspectRatio(contentMode: .fill)`, which — by definition of
            // "fill" — lays out *larger* than the frame it's asked to cover
            // whenever the source image's aspect ratio doesn't exactly match
            // the container's; `.clipped()` above only crops what's
            // *rendered*, not the view's actual layout geometry. Without an
            // explicit shape, a `Button`/`NavigationLink` wrapping this
            // infers its tappable region from that oversized, unclipped
            // geometry rather than the visually clipped frame, so this
            // view's real hit-test area came out roughly 1.9–2x its own
            // width — confirmed via a live accessibility-tree dump on the
            // hero rail, where every loaded page's reported frame was ~758pt
            // wide against a 402pt page/screen width (one page still on its
            // loading placeholder, with no aspect-filled image yet, measured
            // correctly at 402pt in the same dump — isolating the backdrop
            // image specifically). In a `HStack` of same-sized overlapping
            // hittable regions, UIKit resolves the overlap to whichever
            // sibling is later in hit-test order, which here was
            // consistently the *next* page — matching the reported "right
            // side taps the next item, left side taps this one" asymmetry.
            // Pinning the tappable shape to this view's own laid-out bounds
            // makes it exactly `.clipped()`'s frame, matching what's
            // actually visible, regardless of what the backdrop image
            // underneath does.
            .contentShape(Rectangle())
    }

    /// `title`, plus `episodeNumberAccessibilityText` and `episodeTitle`
    /// when present — e.g. "Top Gear, season 19 episode 6, Africa Special"
    /// — see `body`'s own doc comment for why this view needs an explicit
    /// label on a dedicated accessibility layer, rather than leaning on its
    /// (image-heavy) visual content's own auto-derived accessibility
    /// content.
    private var accessibilityLabelText: String {
        guard let episodeTitle else { return title }
        guard let episodeNumberAccessibilityText else { return "\(title), \(episodeTitle)" }
        return "\(title), \(episodeNumberAccessibilityText), \(episodeTitle)"
    }

    private var tiltRotation: (angle: Angle, axis: (x: CGFloat, y: CGFloat, z: CGFloat)) {
        Self.rotation(tiltX: tiltX, tiltY: tiltY, maxDegrees: Self.backdropMaxRotationDegrees)
    }

    private var logoRotation: (angle: Angle, axis: (x: CGFloat, y: CGFloat, z: CGFloat)) {
        Self.rotation(tiltX: tiltX, tiltY: tiltY, maxDegrees: Self.logoMaxRotationDegrees)
    }

    /// A single combined rotation from independent `tiltX`/`tiltY`
    /// components, rather than two chained `.rotation3DEffect`s (one per
    /// axis) — chaining would run the perspective projection twice,
    /// compounding into a far more extreme distortion than either
    /// `maxDegrees` value alone suggests. The axis is perpendicular to the
    /// tilt direction, the same way tipping a picture frame by hand rotates
    /// it around an axis that's *across* the direction you're tipping it,
    /// not *along* it — tilting the device to the right (positive `tiltX`)
    /// rotates the layer around a roughly-vertical axis, tilting it forward
    /// (positive `tiltY`) rotates it around a roughly-horizontal one. Angle
    /// scales with how far off-center the combined tilt is, clamped to
    /// `maxDegrees` at full tilt.
    ///
    /// Not `private` specifically so `BackdropLogoOverlayTests` can pin down
    /// this one piece of real logic directly, same reasoning as
    /// `DeviceTiltObserver.smoothed`/`uprightRelativeY` — everything else
    /// about this view is rendering, not computation.
    static func rotation(
        tiltX: CGFloat, tiltY: CGFloat, maxDegrees: Double
    ) -> (angle: Angle, axis: (x: CGFloat, y: CGFloat, z: CGFloat)) {
        let magnitude = min(1, (tiltX * tiltX + tiltY * tiltY).squareRoot())
        guard magnitude > 0.001 else { return (.zero, (x: 1, y: 0, z: 0)) }
        return (.degrees(Double(magnitude) * maxDegrees), (x: tiltY, y: -tiltX, z: 0))
    }

    private var titleText: some View {
        Text(title)
            .font(.title.bold())
            .foregroundStyle(.white)
            .multilineTextAlignment(textAlignment)
    }

    /// `TextAlignment` has no direct `HorizontalAlignment` conversion —
    /// `.leading`/`.trailing` map straight across, anything else (in
    /// practice, just `.center`) falls back to `.center` too, the only
    /// other value either call site actually passes.
    private var textAlignment: TextAlignment {
        switch alignment {
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
    }
}

/// Renders `url` via `LocalFileImage` when it's a local file (an offline
/// download's own artwork) or `AsyncRemoteImage` otherwise (a live item's
/// network artwork) — the one place `BackdropLogoOverlay` needs to know
/// which of the two it's dealing with, so neither caller has to say so
/// explicitly.
private struct AdaptiveArtworkImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var placeholderSystemImage: String = "photo"

    var body: some View {
        if url?.isFileURL == true {
            LocalFileImage(url: url, contentMode: contentMode, placeholderSystemImage: placeholderSystemImage)
        } else {
            // `.extended` retry patience — this is the hero backdrop, the
            // single most prominent image on whichever screen renders it,
            // worth `RemoteImageLoader.heroMaxAttempts`' extra attempts on
            // a slow/cold server. The local-file branch above has no
            // network retry concept to extend.
            AsyncRemoteImage(
                url: url, contentMode: contentMode,
                placeholderSystemImage: placeholderSystemImage, retryPatience: .extended
            )
        }
    }
}
