import Foundation

/// View-friendly wrapper around a `BaseItemDto`: precomputed display
/// strings and image URLs, so feature/view code never touches Jellyfin's
/// raw field names or tick-based units directly.
struct MediaItem: Identifiable {
    let dto: BaseItemDto
    private let images: ImageURLBuilder

    init(dto: BaseItemDto, images: ImageURLBuilder) {
        self.dto = dto
        self.images = images
    }

    var id: String { dto.id }
    var name: String { dto.name }
    var overview: String? { dto.overview }
    var kind: BaseItemKind { dto.type }
    var genres: [String] { dto.genres ?? [] }
    var ageRating: String? { dto.officialRating }
    var communityRating: Double? { dto.communityRating }
    var seriesID: String? { dto.seriesId }

    /// e.g. "2019" for a movie, "2019–2021" or "2019–" (still airing, best
    /// guess since we don't yet read Jellyfin's `Status` field) for a series.
    var yearText: String? {
        guard let year = dto.productionYear else { return nil }
        guard dto.type == .series else { return String(year) }

        if let endDate = dto.endDate {
            let endYear = Calendar.current.component(.year, from: endDate)
            return endYear == year ? String(year) : "\(year)\u{2013}\(endYear)"
        }
        return "\(year)\u{2013}"
    }

    var durationText: String? {
        guard let ticks = dto.runTimeTicks, ticks > 0 else { return nil }
        let totalMinutes = Int(ticks / 10_000_000 / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// e.g. "S1:E4" for an episode.
    var episodeLabel: String? {
        guard dto.type == .episode, let season = dto.parentIndexNumber, let episode = dto.indexNumber else {
            return nil
        }
        return "S\(season):E\(episode)"
    }

    /// First line shown under a poster card. Episodes surface their series
    /// name (so a row of Continue Watching reads as show titles, not a wall
    /// of episode titles); everything else uses the item's own name.
    var railTitle: String {
        switch dto.type {
        case .episode: return dto.seriesName ?? name
        default:       return name
        }
    }

    /// Second line shown under a poster card, or nil to hide it entirely.
    /// - Movies: release year and runtime (either alone if the other is
    ///   missing).
    /// - Episodes: `S1:E4 · Episode Name` (falls back to the episode name
    ///   alone when the numbering isn't present).
    /// - Series: release year range from `yearText`.
    var railSubtitle: String? {
        switch dto.type {
        case .movie:
            let parts = [yearText, durationText].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
        case .episode:
            return episodeLabel.map { "\($0) \u{00B7} \(name)" } ?? name
        case .series:
            return yearText
        default:
            return nil
        }
    }

    var resumePositionSeconds: Double? {
        guard let ticks = dto.userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return Double(ticks) / 10_000_000
    }

    var playedFraction: Double? {
        if let percentage = dto.userData?.playedPercentage { return percentage / 100 }
        // Fallback: Jellyfin's `playedPercentage` sometimes lags behind a
        // freshly-written `playbackPositionTicks`, so compute the ratio
        // ourselves when we have both endpoints of the calculation.
        if let positionTicks = dto.userData?.playbackPositionTicks, positionTicks > 0,
           let runTimeTicks = dto.runTimeTicks, runTimeTicks > 0 {
            return Double(positionTicks) / Double(runTimeTicks)
        }
        return nil
    }

    var isPlayed: Bool { dto.userData?.played ?? false }

    /// True when the user has started but not finished this item. For movies,
    /// that's a mid-playback position; for shows, some-but-not-all episodes
    /// watched (Jellyfin surfaces both as `playedPercentage`).
    var isPartWatched: Bool {
        guard !isPlayed, let fraction = playedFraction else { return false }
        return fraction > 0 && fraction < 1
    }

    var technicalSummary: [String] {
        guard let source = dto.mediaSources?.first else { return [] }
        var parts: [String] = []
        if let container = source.container { parts.append(container.uppercased()) }
        if let video = source.mediaStreams?.first(where: { $0.type == "Video" })?.codec {
            parts.append(video.uppercased())
        }
        let audioLanguages = source.mediaStreams?
            .filter { $0.type == "Audio" }
            .compactMap { $0.language ?? $0.displayTitle } ?? []
        if !audioLanguages.isEmpty { parts.append("Audio: \(audioLanguages.joined(separator: ", "))") }
        let subtitleCount = source.mediaStreams?.filter { $0.type == "Subtitle" }.count ?? 0
        if subtitleCount > 0 { parts.append("\(subtitleCount) subtitle track\(subtitleCount == 1 ? "" : "s")") }
        return parts
    }

    func imageURL(type: String = "Primary", maxWidth: Int? = nil) -> URL? {
        images.url(itemID: id, imageType: type, tag: dto.imageTags?[type], maxWidth: maxWidth)
    }

    var primaryImageURL: URL? { imageURL(type: "Primary", maxWidth: 500) }
    var logoImageURL: URL? { imageURL(type: "Logo", maxWidth: 600) }

    var backdropImageURL: URL? {
        if let tag = dto.backdropImageTags?.first {
            return images.url(itemID: id, imageType: "Backdrop", tag: tag, maxWidth: 1600)
        }
        if let parentID = dto.parentBackdropItemId, let tag = dto.parentBackdropImageTags?.first {
            return images.url(itemID: parentID, imageType: "Backdrop", tag: tag, maxWidth: 1600)
        }
        return nil
    }
}

extension MediaItem: Hashable {
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.dto == rhs.dto }
    func hash(into hasher: inout Hasher) { hasher.combine(dto) }
}
