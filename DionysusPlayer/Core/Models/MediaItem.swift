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

    var resumePositionSeconds: Double? {
        guard let ticks = dto.userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return Double(ticks) / 10_000_000
    }

    var playedFraction: Double? {
        dto.userData?.playedPercentage.map { $0 / 100 }
    }

    var isPlayed: Bool { dto.userData?.played ?? false }

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
