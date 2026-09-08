import SwiftUI
import UIKit

/// Loads a logo image via `RemoteImageLoader` (retry-with-backoff, caching —
/// same rationale as `AsyncRemoteImage`, not reused directly here since this
/// needs its own fade-in-on-success and custom fallback behavior rather than
/// a placeholder rectangle). Rather than showing `fallback` the instant
/// loading starts, holds off for `fallbackRevealDelay` to give a fast
/// (cached or fast-network) load a chance to resolve invisibly first —
/// only fading `fallback` in if the logo genuinely isn't ready by then, or
/// immediately if every retry fails outright before the delay elapses.
/// Once the logo does resolve, it cross-fades in over whatever `fallback`
/// is currently showing (or straight onto nothing, if the delay hadn't
/// elapsed yet).
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
    /// Fires whenever `showFallback` actually changes value — a plain
    /// observability hook, not used by any production call site.
    /// `fallback` normally sits inside an accessibility-hidden or
    /// `.ignore`-collapsed subtree (see `BackdropLogoOverlay`/
    /// `PlayerControlsOverlay`'s own accessibility layers), so this is the
    /// only way `DionysusPlayerUITests` can observe the delayed-reveal
    /// timing at all; callers wire it to a `UITestConfiguration.isActive`-gated
    /// signal on their own already-accessible layer rather than exposing
    /// this view's internals directly.
    var onFallbackVisibilityChange: ((Bool) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Phase
    /// Whether `fallback` is allowed to render yet — independent of
    /// `phase`, which tracks "what data do we have" rather than "what are
    /// we showing right now". Starts `false` even once `phase` is
    /// `.loading`; see `fallbackRevealDelay`.
    @State private var showFallback: Bool

    /// How long a logo gets to resolve silently before `fallback` is
    /// allowed to appear at all, so a fast (cached or fast-network) load
    /// never flashes the fallback first. Skipped entirely — revealed
    /// immediately — the moment the fetch definitively fails; see
    /// `fetchImage()`'s `catch` branch.
    // Computed rather than stored `static let` — `LogoImageView` is
    // generic over `Fallback`, and Swift doesn't support static *stored*
    // properties on a generic type.
    private static var fallbackRevealDelay: Duration { .seconds(1) }
    /// Matches `FadeInLogoImage`'s own fade-in duration, so the delayed
    /// fallback reveal and the eventual logo reveal share the same
    /// "how briskly things settle in" feel rather than introducing a
    /// second, differently-tuned timing in this view.
    private static var fallbackFadeDuration: Double { 0.35 }

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
    init(
        url: URL, fallback: Fallback, retryPatience: AsyncRemoteImage.RetryPatience = .standard,
        onFallbackVisibilityChange: ((Bool) -> Void)? = nil
    ) {
        self.url = url
        self.fallback = fallback
        self.retryPatience = retryPatience
        self.onFallbackVisibilityChange = onFallbackVisibilityChange
        if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            _phase = State(initialValue: .success(cached, animated: false))
        } else {
            _phase = State(initialValue: .loading)
        }
        _showFallback = State(initialValue: false)
    }

    private enum Phase {
        case loading
        case success(UIImage, animated: Bool)
        case failure
    }

    private var isSuccess: Bool {
        if case .success = phase { return true }
        return false
    }

    /// The *effective* visibility `body` actually renders — `showFallback`
    /// alone isn't enough, since it stays `true` once set and only `phase`
    /// reaching `.success` hides `fallback` again (see `body`'s own doc
    /// comment). `onFallbackVisibilityChange` has to track this combined
    /// value, not raw `showFallback`, or it would fire once on the way up
    /// and never again on the way back down.
    private var isFallbackVisible: Bool { showFallback && !isSuccess }

    /// A `ZStack`, not a hard-switching `Group`, so `fallback` and the
    /// incoming logo can cross-fade rather than pop from one to the other.
    /// `fallback` only renders once `showFallback` has been allowed to
    /// turn on (see `fallbackRevealDelay`) *and* the logo hasn't already
    /// resolved — the moment `phase` reaches `.success`, `fallback` is
    /// hidden again on the spot even if it was already showing.
    var body: some View {
        ZStack {
            if showFallback, !isSuccess { fallback }
            if case .success(let image, let animated) = phase {
                FadeInLogoImage(image: Image(uiImage: image), animated: animated, reduceMotion: reduceMotion)
            }
        }
        .task(id: url) { await load() }
        .onChange(of: isFallbackVisible) { _, newValue in
            onFallbackVisibilityChange?(newValue)
        }
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
            setShowFallback(false)
            return
        }
        phase = .loading
        setShowFallback(false)

        // Races the fallback-reveal delay against the actual fetch: an
        // explicit `Task` handle, cancelled via `defer` the moment
        // `fetchImage()` returns (success or failure), rather than
        // `async let` — an un-cancelled `async let` is *awaited to
        // completion* at end of scope on a normal return, not
        // auto-cancelled, which would block this function for the full
        // remaining delay even after a fast/cached success.
        let revealTask = Task { await revealFallbackAfterDelay() }
        defer { revealTask.cancel() }
        await fetchImage()
    }

    private func revealFallbackAfterDelay() async {
        do {
            try await Task.sleep(for: Self.fallbackRevealDelay)
        } catch {
            // Cancelled — `fetchImage()` already resolved, or this
            // view/url is going away. Either way, nothing to reveal.
            return
        }
        revealFallback()
    }

    private func fetchImage() async {
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
            // Retries exhausted (or a genuine 404 — indistinguishable,
            // see `RemoteImageLoader`'s own doc comment) before the
            // reveal delay elapsed: skip the rest of the timer and
            // reveal `fallback` right away, with the same brief fade as
            // the timeout-triggered reveal, rather than an instant pop —
            // kept visually consistent regardless of *why* fallback is
            // appearing.
            phase = .failure
            revealFallback()
        }
    }

    /// Single entry point for making `fallback` visible, used by both the
    /// delay timing out and a fetch failing outright — guarantees both
    /// paths animate identically and neither double-fires.
    private func revealFallback() {
        guard !showFallback else { return }
        if reduceMotion {
            setShowFallback(true)
        } else {
            withAnimation(.easeIn(duration: Self.fallbackFadeDuration)) {
                setShowFallback(true)
            }
        }
    }

    /// Every `showFallback` write funnels through here purely to skip a
    /// redundant `withAnimation` call when the value isn't actually
    /// changing — `onFallbackVisibilityChange` is driven separately, by
    /// `body`'s `.onChange(of: isFallbackVisible)`, since *that* combined
    /// value (not raw `showFallback`) is what actually goes back to
    /// `false` on success.
    private func setShowFallback(_ value: Bool) {
        guard showFallback != value else { return }
        showFallback = value
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
