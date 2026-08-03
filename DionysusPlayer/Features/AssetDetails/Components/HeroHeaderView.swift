import SwiftUI

/// Backdrop image with a logo (or title text fallback) overlaid at the
/// bottom, Disney+-style.
struct HeroHeaderView: View {
    let item: MediaItem

    var body: some View {
        // The backdrop drives its own width via `.aspectRatio(.fill)` and
        // would otherwise blow out the layout (a 16:9 image at 320pt height is
        // ~569pt wide). Cap it to the ScrollView viewport first, then layer
        // the gradient and logo as overlays so they inherit that constrained
        // frame — placing them as ZStack siblings caused the logo to be
        // positioned relative to the image's oversized frame (which centered
        // under container-relative-frame clipping, pushing the logo half off
        // the left edge).
        AsyncRemoteImage(url: item.backdropImageURL ?? item.primaryImageURL)
            .frame(height: 320)
            .containerRelativeFrame(.horizontal)
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
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fit)
                            }
                        }
                        .frame(maxWidth: 240, maxHeight: 80, alignment: .leading)
                    } else {
                        Text(item.name)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                    }
                }
                .padding()
            }
    }
}
