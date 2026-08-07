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

    @State private var phase: Phase

    /// Seeds `phase` synchronously from whatever's already in
    /// `RemoteImageLoader`'s in-memory cache, rather than always starting
    /// at `.empty` and waiting for `.task` to run. Matters for any view
    /// whose identity gets recreated for an already-loaded image — e.g.
    /// scrolling a rail out of view and back (a `LazyHStack` tears down and
    /// rebuilds offscreen rows), or the same poster appearing in two rails
    /// — where without this, a fresh `AsyncRemoteImage` always started
    /// blank and replayed the placeholder-then-fade even though the image
    /// was already decoded and sitting in memory. Same fix as
    /// `LogoImageView`'s `init`, which hit the identical symptom on the
    /// hero rail's loop-wrap first.
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        if let url, let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            _phase = State(initialValue: .success(cached))
        } else {
            _phase = State(initialValue: .empty)
        }
    }

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
        // Cache hit: resolve synchronously (same check `init` already did —
        // repeated here since `.task` always re-runs once per unique `url`,
        // including right after `init`'s own seeding) rather than going
        // through the `async` `image(for:)` and its actor hop, so there's
        // no window where this could regress back to a blank `.empty`
        // frame before landing on the exact same result.
        if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            phase = .success(cached)
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
