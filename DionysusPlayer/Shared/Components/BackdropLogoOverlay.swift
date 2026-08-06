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
                        LogoImageView(url: logoURL, fallback: titleText)
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
