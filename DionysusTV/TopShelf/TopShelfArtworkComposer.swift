import os
import Foundation

/// Draws each shelf item's art (`TopShelfArtworkRenderer`) and stores it for
/// tvOS (M6). One at a time, within a time budget: the extension has about
/// 22MB (Bedroom), and an item not drawn in time keeps its plain backdrop now
/// and is drawn on a later load.
enum TopShelfArtworkComposer {
    static let budget: Duration = .seconds(6)
    private static let concurrency = 1

    /// File URLs by entry id; an entry missing keeps its backdrop URL.
    static func artwork(for entries: [TopShelfEntry], store: TopShelfArtworkStore?, session: URLSession) async -> [String: URL] {
        guard let store else { return [:] }
        var art: [String: URL] = [:]
        var pending: [TopShelfEntry] = []
        // A marker left behind means the last load died rendering that item:
        // it's marked failed (plain from then on), and this load draws nothing
        // new, so the shelf answers at once; the next carries on.
        let died = entries.filter { store.isMarkedRendering($0.artworkKey) }
        for entry in died {
            store.markFailed(entry.artworkKey)
            store.clearRendering(entry.artworkKey)
        }
        let lastLoadDied = !died.isEmpty
        for entry in entries {
            if let cached = store.existing(for: entry.artworkKey) {
                art[entry.id] = cached
            } else if !lastLoadDied {
                pending.append(entry)
            }
        }

        let deadline = ContinuousClock.now + budget
        await withTaskGroup(of: (String, URL?)?.self) { group in
            var queue = pending[...]
            var remaining = pending.count
            func startNext() {
                guard let entry = queue.popFirst() else { return }
                group.addTask { (entry.id, await compose(entry, store: store, session: session)) }
            }
            guard remaining > 0 else { return }
            // `nil` is the deadline passing.
            group.addTask {
                try? await Task.sleep(until: deadline)
                return nil
            }
            for _ in 0..<concurrency { startNext() }
            for await result in group {
                guard let (id, url) = result else { break }
                if let url { art[id] = url }
                remaining -= 1
                if remaining == 0 { break }
                startNext()
            }
            group.cancelAll()
        }
        store.prune(keeping: Set(entries.map(\.artworkKey)))
        return art
    }

    /// An item whose last render never finished killed the extension then and
    /// would again (tvOS retries, and the shelf stays blank while it does), so
    /// it keeps its plain backdrop until its art changes and the key with it.
    private static func compose(_ entry: TopShelfEntry, store: TopShelfArtworkStore, session: URLSession) async -> URL? {
        guard !store.isFailed(entry.artworkKey) else { return nil }
        store.markRendering(entry.artworkKey)
        defer { store.clearRendering(entry.artworkKey) }
        // The widest canvas that fits now; the backdrop is fetched at that width.
        guard let width = TopShelfArtworkRenderer.pixelWidth(availableBytes: UInt64(os_proc_available_memory())),
              let backdrop = await data(at: entry.image1x.settingMaxWidth(Int(width)), session: session)
        else { return nil }
        let logo = await entry.logoURL.asyncFlatMap { await data(at: $0, session: session) }
        guard !Task.isCancelled,
              let drawn = TopShelfArtworkRenderer.render(
                  backdrop: backdrop, logo: logo, title: entry.title, context: entry.contextTitle,
                  remaining: entry.remainingText, pixelWidth: width
              )
        else { return nil }
        return store.write(drawn, for: entry.artworkKey)
    }

    private static func data(at url: URL, session: URLSession) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}

private extension URL {
    func settingMaxWidth(_ width: Int) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var items = components.queryItems?.filter { $0.name != "maxWidth" } ?? []
        items.append(URLQueryItem(name: "maxWidth", value: String(width)))
        components.queryItems = items
        return components.url ?? self
    }
}

private extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
