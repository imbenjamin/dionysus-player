import Foundation

/// The Info tab's artwork (Benjamin, 2026-10-06): a movie's portrait
/// poster; an episode's landscape thumb (its Thumb, else its still, which is
/// its Primary), falling back to the nearest ancestor's Thumb, in practice
/// the show's.
struct TVPlayerInfoArt: Equatable {
    enum Shape: Equatable {
        case poster, landscape

        var size: CGSize {
            switch self {
            case .poster: CGSize(width: 220, height: 330)
            case .landscape: CGSize(width: 480, height: 270)
            }
        }
    }

    let url: URL?
    let shape: Shape

    init(item: MediaItem) {
        if item.kind == .episode {
            shape = .landscape
            let still = item.dto.imageTags?["Primary"] != nil ? item.imageURL(type: "Primary", maxWidth: 960) : nil
            url = item.thumbImageURL ?? still ?? item.parentThumbImageURL
        } else {
            shape = .poster
            url = item.dto.imageTags?["Primary"] != nil ? item.imageURL(type: "Primary", maxWidth: 440) : nil
        }
    }
}
