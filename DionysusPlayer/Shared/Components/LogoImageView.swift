import SwiftUI
import UIKit

/// Loads a logo image via `RemoteImageLoader` (retry-with-backoff, caching —
/// same rationale as `AsyncRemoteImage`, not reused directly here since this
/// needs its own fade-in-on-success and custom fallback-on-failure behavior
/// rather than a placeholder rectangle) and fades it in once loaded.
///
/// Shared by `BackdropLogoOverlay` (hero header/rail — text-title fallback)
/// and `LandscapeMediaCard`'s episode logo overlay (no fallback — an episode
/// tile already shows its title as text below the artwork, so nothing
/// renders there when there's no logo).
struct LogoImageView<Fallback: View>: View {
    let url: URL
    let fallback: Fallback

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
    /// always started at `.loading` (a blank frame) and then, once `.task`
    /// resolved — from cache, near-instantly, but never *synchronously*
    /// before the first paint, since a `Task` schedules its body rather
    /// than running it inline — replayed the full fade-in, reading as the
    /// logo flashing/reloading even though nothing had actually changed.
    init(url: URL, fallback: Fallback) {
        self.url = url
        self.fallback = fallback
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

    var body: some View {
        Group {
            switch phase {
            case .success(let image, let animated):
                FadeInLogoImage(image: Image(uiImage: image), animated: animated)
            case .failure:
                // Logo failed to load (404, timeout, etc. — retried a few
                // times by RemoteImageLoader first).
                fallback
            case .loading:
                Color.clear
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
            let image = try await RemoteImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            phase = .success(image, animated: true)
        } catch {
            guard !Task.isCancelled else { return }
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

    @State private var opacity: Double

    init(image: Image, animated: Bool = true) {
        self.image = image
        self.animated = animated
        _opacity = State(initialValue: animated ? 0 : 1)
    }

    var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .opacity(opacity)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeIn(duration: 0.35)) {
                    opacity = 1
                }
            }
    }
}
