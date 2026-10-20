import Foundation

/// The detail pages' derived text, kept out of the views so it can be tested.
enum TVDetailFormat {
    /// "Play" or "Resume", with the episode for a show ("Resume S1:E3").
    /// `nil` when there is nothing to play: a show whose seasons hold no
    /// episodes yet, where the page draws no Play button at all.
    static func playTitle(target: MediaItem?, isShow: Bool) -> String? {
        guard let target else { return nil }
        let verb = target.canResume
            ? String(localized: "Resume") : String(localized: "Play")
        // "S1:E3" is a formatted label, not translated (see `MediaItem.episodeLabel`).
        if isShow, let label = target.episodeLabel { return "\(verb) \(label)" }
        return verb
    }

    /// "47 min left", rounded up so the last seconds never read as zero.
    static func timeLeft(runTimeTicks: Int64?, resumeSeconds: Double?) -> String? {
        guard let runTimeTicks, runTimeTicks > 0, let resumeSeconds, resumeSeconds > 0 else { return nil }
        let remaining = Double(runTimeTicks) / 10_000_000 - resumeSeconds
        guard remaining > 0 else { return nil }
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        return String(localized: "\(minutes) min left")
    }

    /// One part of the metadata line: what's drawn, and what VoiceOver says.
    struct MetadataPart: Equatable {
        let text: String
        let spoken: String
    }

    /// Year, age rating, runtime and the first two genres, each only when
    /// the item has it. The runtime is spoken in words: VoiceOver read "1h 48m"
    /// as "1 H 48 meters" (Benjamin, on device, M5).
    static func metadata(for item: MediaItem) -> [MetadataPart] {
        let genres = item.genres.prefix(2).joined(separator: ", ")
        let runtime = item.durationText.map { MetadataPart(text: $0, spoken: item.durationAccessibilityText ?? $0) }
        return [
            item.yearText.map { MetadataPart(text: $0, spoken: $0) },
            item.ageRating.map { MetadataPart(text: $0, spoken: $0) },
            runtime,
            genres.isEmpty ? nil : MetadataPart(text: genres, spoken: genres)
        ].compactMap { $0 }
    }
}
