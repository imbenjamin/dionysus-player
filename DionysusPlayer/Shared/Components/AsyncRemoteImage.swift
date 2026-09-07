import SwiftUI
import UIKit

/// Loads a remote image via `RemoteImageLoader` (retry-with-backoff,
/// in-memory + disk caching, in-flight de-duplication — see that type's doc
/// comment for why plain `AsyncImage` wasn't sufficient) with consistent
/// placeholder/failure styling, used everywhere posters, backdrops, and
/// logos are shown.
struct AsyncRemoteImage: View {
    /// How many attempts/how much backoff `RemoteImageLoader` should give
    /// this particular image before giving up — see that type's
    /// `heroMaxAttempts`/`heroRetryBaseDelay` doc comments. `.standard`
    /// (the default) uses the loader's own configured defaults; `.extended`
    /// is reserved for the single most prominent image per screen (the
    /// hero backdrop/logo), which is worth spending extra attempts on.
    enum RetryPatience {
        case standard
        case extended
    }

    var url: URL?
    var contentMode: ContentMode = .fill
    /// The SF Symbol `MediaPlaceholderBox` shows while this image is
    /// loading or has failed — pass a content-representative glyph (e.g.
    /// `BaseItemKind.placeholderSystemImage`) rather than leaving the
    /// generic default wherever the caller knows what kind of content this
    /// is.
    var placeholderSystemImage: String = "photo"
    var glyphSize: CGFloat = 28
    var retryPatience: RetryPatience = .standard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    init(
        url: URL?,
        contentMode: ContentMode = .fill,
        placeholderSystemImage: String = "photo",
        glyphSize: CGFloat = 28,
        retryPatience: RetryPatience = .standard
    ) {
        self.url = url
        self.contentMode = contentMode
        self.placeholderSystemImage = placeholderSystemImage
        self.glyphSize = glyphSize
        self.retryPatience = retryPatience
        if let url, let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            _phase = State(initialValue: .success(cached))
        } else if url == nil {
            // No URL to even try — e.g. a cast member with no image tag at
            // all. Settled from the start, not "loading": there's nothing
            // in flight for the shimmer to be indicating.
            _phase = State(initialValue: .failure)
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
            .animation(reduceMotion ? nil : .default, value: phase)
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .success(let uiImage):
            Image(uiImage: uiImage).resizable().aspectRatio(contentMode: contentMode)
        case .empty:
            MediaPlaceholderBox(systemImage: placeholderSystemImage, glyphSize: glyphSize, isSettled: false)
        case .failure:
            MediaPlaceholderBox(systemImage: placeholderSystemImage, glyphSize: glyphSize, isSettled: true)
        }
    }

    private func load() async {
        guard let url else {
            // See `init`'s identical reasoning — no URL means nothing to
            // load, so this is a settled, static state, not "in progress."
            phase = .failure
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
            let image: UIImage
            switch retryPatience {
            case .standard:
                image = try await RemoteImageLoader.shared.image(for: url)
            case .extended:
                image = try await RemoteImageLoader.shared.image(
                    for: url,
                    maxAttempts: RemoteImageLoader.heroMaxAttempts,
                    retryBaseDelay: RemoteImageLoader.heroRetryBaseDelay
                )
            }
            guard !Task.isCancelled else { return }
            phase = .success(image)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure
        }
    }
}
