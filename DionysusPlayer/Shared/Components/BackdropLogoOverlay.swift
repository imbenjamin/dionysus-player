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
struct BackdropLogoOverlay: View {
    let item: MediaItem

    var body: some View {
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
                AsyncRemoteImage(url: item.backdropImageURL ?? item.primaryImageURL)
            }
            .clipped()
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                Group {
                    if let logoURL = item.logoImageURL {
                        AsyncImage(url: logoURL) { phase in
                            switch phase {
                            case .success(let image):
                                FadeInLogoImage(image: image)
                            case .failure:
                                // Logo failed to load (404, timeout, etc.) —
                                // fall back to the text title rather than
                                // leaving the overlay blank.
                                titleText
                            case .empty:
                                Color.clear
                            @unknown default:
                                Color.clear
                            }
                        }
                        .frame(maxWidth: 240, maxHeight: 80, alignment: .leading)
                    } else {
                        titleText
                    }
                }
                .padding()
            }
    }

    private var titleText: some View {
        Text(item.name)
            .font(.title.bold())
            .foregroundStyle(.white)
    }
}

/// Fades a loaded logo `Image` in over `duration`, rather than having it pop
/// in the instant `AsyncImage` resolves.
///
/// Deliberately *not* done via `AsyncImage(url:transaction:)` +
/// `.transition(.opacity)` on the success case — that combination is
/// unreliable in practice: whether it animates depends on `AsyncImage`
/// internally treating the `.empty` → `.success` switch as a tracked state
/// change under the given transaction, which isn't guaranteed, especially
/// when the image resolves from cache fast enough that the `.empty` phase
/// never visibly renders. Owning the opacity as local `@State` and animating
/// it from `onAppear` sidesteps `AsyncImage`'s phase-transition behavior
/// entirely — this view's `body` only runs once the image has already
/// loaded, so `onAppear` firing *is* the "just loaded" signal, independent
/// of whatever transaction `AsyncImage` used internally.
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
