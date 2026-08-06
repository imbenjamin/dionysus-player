import SwiftUI
import UIKit

/// Loads a remote image via `RemoteImageLoader` (retry-with-backoff,
/// in-memory + disk caching, in-flight de-duplication — see that type's doc
/// comment for why plain `AsyncImage` wasn't sufficient) with consistent
/// placeholder/failure styling, used everywhere posters, backdrops, and
/// logos are shown.
struct AsyncRemoteImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill

    @State private var phase: Phase = .empty

    private enum Phase: Equatable {
        case empty
        case success(UIImage)
        case failure

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.empty, .empty), (.failure, .failure): true
            case (.success(let l), .success(let r)): l === r
            default: false
            }
        }
    }

    var body: some View {
        content
            .animation(.default, value: phase)
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .success(let uiImage):
            Image(uiImage: uiImage).resizable().aspectRatio(contentMode: contentMode)
        case .empty:
            placeholder.overlay { if url != nil { ProgressView().tint(.dionysusPrimary) } }
        case .failure:
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle().fill(Color.gray.opacity(0.2))
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        phase = .empty
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
