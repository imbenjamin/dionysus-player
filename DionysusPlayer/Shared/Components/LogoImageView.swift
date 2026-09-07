import SwiftUI
import UIKit

/// Loads a logo image via `RemoteImageLoader` (retry-with-backoff, caching —
/// same rationale as `AsyncRemoteImage`, not reused directly here since this
/// needs its own fade-in-on-success and custom fallback behavior rather than
/// a placeholder rectangle). Shows `fallback` immediately while the logo is
/// loading (not a blank gap) and cross-fades to the real logo once it
/// resolves, staying on `fallback` for good if every retry fails.
///
/// Shared by `BackdropLogoOverlay` (hero header/rail — text-title fallback)
/// and `LandscapeMediaCard`'s episode logo overlay (no fallback — an episode
/// tile already shows its title as text below the artwork, so nothing
/// renders there whether the logo is loading or missing).
struct LogoImageView<Fallback: View>: View {
    let url: URL
    let fallback: Fallback
    /// See `AsyncRemoteImage.RetryPatience`'s doc comment — reused here
    /// rather than a duplicate type, since the concept (and the
    /// hero-only `.extended` use case) is identical.
    var retryPatience: AsyncRemoteImage.RetryPatience = .standard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Phase

    /// Seeds `phase` synchronously from whatever's already in
    /// `RemoteImageLoader`'s in-memory cache, rather than always starting
    /// at `.loading` and waiting for `.task` to run. Matters specifically
    /// for the hero rail's loop-wrap: swiping past the first/last item
    /// lands on `HeroRailView.loopedItems`' padding page — a pixel-identical
    /// stand-in for a real page, but a *structurally different* view (its
    /// own `.id`, per that property's doc comment), so it gets a brand-new
    /// `LogoImageView` with fresh `@State` even though the same logo was
    /// already on screen a moment before. Without this, that fresh instance
    /// always started at `.loading` (briefly showing `fallback` again) and
    /// then, once `.task` resolved — from cache, near-instantly, but never *synchronously*
    /// before the first paint, since a `Task` schedules its body rather
    /// than running it inline — replayed the full fade-in, reading as the
    /// logo flashing/reloading even though nothing had actually changed.
    init(url: URL, fallback: Fallback, retryPatience: AsyncRemoteImage.RetryPatience = .standard) {
        self.url = url
        self.fallback = fallback
        self.retryPatience = retryPatience
        if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            _phase = State(initialValue: .success(cached, animated: false))
        } else {
            _phase = State(initialValue: .loading)
        }
    }

    private enum Phase {
        case loading
        case success(UIImage, animated: Bool)
        case failure
    }

    /// A `ZStack`, not a hard-switching `Group`, so `fallback` and the
    /// incoming logo can cross-fade rather than pop from one to the other.
    /// `fallback` renders for both `.loading` and `.failure` — showing it
    /// immediately while the logo is still in flight (rather than the
    /// previous `Color.clear`, fully invisible loading state) means a
    /// caller's text-title fallback (`BackdropLogoOverlay`) or `EmptyView`
    /// (`LandscapeMediaCard`'s episode overlay, where the title's already
    /// shown as text below) is what the user sees the whole time a logo
    /// hasn't resolved yet, not a lengthening blank gap.
    var body: some View {
        ZStack {
            if case .success = phase {} else { fallback }
            if case .success(let image, let animated) = phase {
                FadeInLogoImage(image: Image(uiImage: image), animated: animated, reduceMotion: reduceMotion)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        // Cache hit: resolve synchronously (same check `init` already did —
        // repeated here since `.task` always re-runs once per unique `url`,
        // including right after `init`'s own seeding) rather than going
        // through the `async` `image(for:)` and its actor hop, so there's
        // no window where this could regress back to a blank `.loading`
        // frame before landing on the exact same result.
        if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            phase = .success(cached, animated: false)
            return
        }
        phase = .loading
        do {
            let image: UIImage
            switch retryPatience {
            case .standard:
                image = try await RemoteImageLoader.shared.image(for: url)
            case .extended:
                image = try await RemoteImageLoader.shared.image(
                    for: url,
                    maxAttempts: RemoteImageLoader.heroMaxAttempts,
                    retryBaseDelay: RemoteImageLoader.heroRetryBaseDelay
                )
            }
            guard !Task.isCancelled else { return }
            if reduceMotion {
                phase = .success(image, animated: false)
            } else {
                withAnimation(.easeInOut(duration: 0.35)) {
                    phase = .success(image, animated: true)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            // No visual change needed here — `fallback` was already
            // showing throughout `.loading`, so nothing needs to animate
            // when retries quietly exhaust.
            phase = .failure
        }
    }
}

/// Fades a loaded logo `Image` in over `duration`, rather than having it pop
/// in the instant it resolves — unless `animated` is `false` (an
/// already-cached image being redisplayed), in which case it's shown at
/// full opacity immediately, since there's no load latency to soften and
/// nothing has actually changed for the user to see fade back in.
///
/// Deliberately *not* done via `AsyncImage(url:transaction:)` +
/// `.transition(.opacity)` on the success case — that combination is
/// unreliable in practice: whether it animates depends on `AsyncImage`
/// internally treating the `.empty` → `.success` switch as a tracked state
/// change under the given transaction, which isn't guaranteed, especially
/// when the image resolves from cache fast enough that the `.empty` phase
/// never visibly renders. Owning the opacity as local `@State` and animating
/// it from `onAppear` sidesteps that phase-transition behavior entirely —
/// this view's `body` only runs once the image has already loaded, so
/// `onAppear` firing *is* the "just loaded" signal.
private struct FadeInLogoImage: View {
    let image: Image
    var animated: Bool = true
    /// Passed in from the caller rather than read via this view's own
    /// `@Environment`, so there's one source of truth with
    /// `LogoImageView.load()`'s own reduce-motion branch rather than two
    /// independent reads that could disagree.
    var reduceMotion: Bool = false

    @State private var opacity: Double

    init(image: Image, animated: Bool = true, reduceMotion: Bool = false) {
        self.image = image
        self.animated = animated
        self.reduceMotion = reduceMotion
        _opacity = State(initialValue: animated && !reduceMotion ? 0 : 1)
    }

    var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .opacity(opacity)
            .onAppear {
                guard animated, !reduceMotion else {
                    opacity = 1
                    return
                }
                withAnimation(.easeIn(duration: 0.35)) {
                    opacity = 1
                }
            }
    }
}
