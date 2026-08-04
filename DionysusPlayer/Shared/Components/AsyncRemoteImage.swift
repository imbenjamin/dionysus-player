import SwiftUI

/// `AsyncImage` with consistent placeholder/failure styling used everywhere
/// posters, backdrops, and logos are shown.
struct AsyncRemoteImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .default)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .empty:
                placeholder.overlay { if url != nil { ProgressView().tint(.dionysusPrimary) } }
            case .failure:
                placeholder
            @unknown default:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        Rectangle().fill(Color.gray.opacity(0.2))
    }
}
