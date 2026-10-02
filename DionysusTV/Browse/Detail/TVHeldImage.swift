import SwiftUI

/// Holds what is on screen until the next image has loaded (Benjamin,
/// 2026-10-02). A show's page changes its backdrop, logo and side image as
/// the episode or season changes; swapped at once, an image not yet cached
/// left its space empty until it arrived, a flash between two pictures.
///
/// `content` is built with the value on show, which changes to the new one
/// only once its image is in `RemoteImageLoader`'s cache, so the views
/// inside find it there and draw it without a loading state. A value with no
/// image, or one whose image fails, is shown as soon as that's known.
struct TVHeldImage<Value: Equatable, Content: View>: View {
    let value: Value
    let url: (Value) -> URL?
    @ViewBuilder let content: (Value) -> Content
    @State private var shown: Value

    init(_ value: Value, url: @escaping (Value) -> URL?, @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value
        self.url = url
        self.content = content
        _shown = State(initialValue: value)
    }

    var body: some View {
        content(shown)
            .animation(.easeInOut(duration: 0.3), value: shown)
            .task(id: url(value)) {
                guard shown != value else { return }
                if let url = url(value), RemoteImageLoader.shared.cachedImage(for: url) == nil {
                    _ = try? await RemoteImageLoader.shared.image(for: url)
                    guard !Task.isCancelled else { return }
                }
                shown = value
            }
            // The same image, something else changed (a resume point).
            .onChange(of: value) { _, new in
                if url(new) == url(shown) { shown = new }
            }
    }
}
