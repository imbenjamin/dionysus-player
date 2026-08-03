import SwiftUI

/// Backdrop image with a logo (or title text fallback) overlaid at the
/// bottom, Disney+-style.
struct HeroHeaderView: View {
    let item: MediaItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncRemoteImage(url: item.backdropImageURL ?? item.primaryImageURL)
                .frame(height: 320)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)

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
