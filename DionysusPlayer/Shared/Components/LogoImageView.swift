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

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case success(UIImage)
        case failure
    }

    var body: some View {
        Group {
            switch phase {
            case .success(let image):
                FadeInLogoImage(image: Image(uiImage: image))
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
        phase = .loading
        do {
            let image = try await RemoteImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            phase = .success(image)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure
        }
    }
}

/// Fades a loaded logo `Image` in over `duration`, rather than having it pop
/// in the instant it resolves.
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

    @State private var opacity: Double = 0

    var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeIn(duration: 0.35)) {
                    opacity = 1
                }
            }
    }
}
