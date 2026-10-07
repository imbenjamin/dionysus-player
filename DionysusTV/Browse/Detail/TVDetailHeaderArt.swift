import SwiftUI

/// The image shown beside the title on a detail page whose item has no
/// backdrop (Benjamin, 2026-10-02): a movie's poster, a show's or an
/// episode's thumb. `nil` when the item has a backdrop, or no image to show.
struct TVDetailHeaderArt: Equatable {
    enum Shape: Equatable {
        case poster
        case landscape

        var size: CGSize {
            switch self {
            case .poster: CGSize(width: 400, height: 600)
            case .landscape: CGSize(width: 720, height: 405)
            }
        }
    }

    let url: URL
    let shape: Shape

    init?(item: MediaItem) {
        guard item.backdropImageURL == nil else { return nil }
        // `imageURL(type:)` builds a URL whether or not the item has that
        // image, so the tag is checked first.
        func url(_ type: String, _ shape: Shape) -> URL? {
            guard item.dto.imageTags?[type] != nil else { return nil }
            return item.imageURL(type: type, maxWidth: Int(shape.size.width) * 2)
        }
        let isShowContent = [.series, .season, .episode].contains(item.kind)
        if isShowContent, let thumb = url("Thumb", .landscape) {
            self.url = thumb
            shape = .landscape
        } else if item.kind == .episode, let still = url("Primary", .landscape) {
            // An episode's Primary image is its still frame.
            self.url = still
            shape = .landscape
        } else if let poster = url("Primary", .poster) {
            self.url = poster
            shape = .poster
        } else {
            return nil
        }
    }
}

/// Draws `TVDetailHeaderArt` at the header's right edge. It sits in the
/// header, so it scrolls away with the title.
struct TVDetailHeaderArtView: View {
    let art: TVDetailHeaderArt
    let placeholderSystemImage: String

    var body: some View {
        AsyncRemoteImage(url: art.url, placeholderSystemImage: placeholderSystemImage, retryPatience: .extended)
            .frame(width: art.shape.size.width, height: art.shape.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .accessibilityHidden(true)
            // The element is a layer of the frame's own size: on the image,
            // it took the image's unclipped fill (720×1080 for a portrait
            // picture in a 720×405 frame, measured). An element, not hidden:
            // hidden, XCUITest can't see it either.
            .overlay {
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel(String(localized: "Artwork"))
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier(A11yID.TV.Detail.headerArt)
            }
    }
}

extension View {
    /// A box set's or a playlist's header: short over a backdrop, and the
    /// full first screen with the poster beside the title when there's none,
    /// as on a movie's page (Benjamin, 2026-10-05).
    @ViewBuilder
    func tvDetailHeaderFrameWhenNoBackdrop(art item: MediaItem) -> some View {
        if TVDetailHeaderArt(item: item) != nil {
            tvDetailHeaderFrame(art: item)
        } else {
            self
        }
    }

    /// Sizes a detail page's header to the first screen, with the item's
    /// poster or thumb at its right when it has no backdrop. A poster stands
    /// at the bottom, beside the title; a thumb is wide enough to reach the
    /// synopsis there, so it sits top-right, clear of the text (Benjamin,
    /// 2026-10-07).
    func tvDetailHeaderFrame(art item: MediaItem) -> some View {
        let isLandscape = TVDetailHeaderArt(item: item)?.shape == .landscape
        return frame(maxWidth: .infinity, minHeight: TVDetailMetrics.headerHeight, alignment: .bottomLeading)
            .overlay(alignment: isLandscape ? .topTrailing : .bottomTrailing) {
                TVHeldImage(TVDetailHeaderArt(item: item), url: { $0?.url }) { art in
                    if let art {
                        TVDetailHeaderArtView(art: art, placeholderSystemImage: item.kind.placeholderSystemImage)
                            .padding(.trailing, 100)
                            .padding(isLandscape ? .top : .bottom, isLandscape ? TVDetailMetrics.landscapeArtTop : 20)
                    }
                }
            }
    }
}
