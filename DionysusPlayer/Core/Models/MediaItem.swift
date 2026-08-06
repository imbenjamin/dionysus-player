import Foundation

/// A cast/crew credit ready for display — see `MediaItem.cast`.
struct CastMember: Identifiable, Hashable {
    var id: String
    var name: String
    var role: String?
    var imageURL: URL?
}

/// Container/codec/resolution/dynamic-range summary plus per-track audio
/// and subtitle lists for a detail page's "Details" tab — see
/// `MediaItem.technicalDetails`. All fields are already display-formatted
/// strings; nothing here needs further unit conversion by the view.
struct TechnicalDetails: Equatable {
    var container: String?
    var videoCodec: String?
    var resolution: String?
    var dynamicRange: String?
    var bitrate: String?
    var fileSize: String?
    var audioTracks: [String]
    var subtitleTracks: [String]

    var isEmpty: Bool {
        container == nil && videoCodec == nil && resolution == nil && dynamicRange == nil
            && bitrate == nil && fileSize == nil && audioTracks.isEmpty && subtitleTracks.isEmpty
    }
}

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

    var isFavorite: Bool { dto.userData?.isFavorite ?? false }

    /// True when the user has started but not finished this item. For movies,
    /// that's a mid-playback position; for shows, some-but-not-all episodes
    /// watched (Jellyfin surfaces both as `playedPercentage`).
    var isPartWatched: Bool {
        guard !isPlayed, let fraction = playedFraction else { return false }
        return fraction > 0 && fraction < 1
    }

    /// Container/codec/resolution/dynamic-range summary plus per-track audio
    /// and subtitle lists, for the detail page's "Details" tab. `nil` when
    /// there's no media source at all (e.g. viewing a Series, which has no
    /// file of its own — only its episodes do).
    var technicalDetails: TechnicalDetails? {
        guard let source = dto.mediaSources?.first else { return nil }
        let streams = source.mediaStreams ?? []
        let videoStream = streams.first { $0.type == "Video" }

        var resolution: String?
        if let width = videoStream?.width, let height = videoStream?.height {
            resolution = Self.resolutionLabel(width: width, height: height)
        }
        let dynamicRange = (videoStream?.videoRangeType ?? videoStream?.videoRange)
            .flatMap { $0.isEmpty || $0 == "Unknown" ? nil : Self.friendlyDynamicRangeName($0) }

        let details = TechnicalDetails(
            container: source.container?.uppercased(),
            videoCodec: videoStream?.codec.map(Self.friendlyVideoCodecName),
            resolution: resolution,
            dynamicRange: dynamicRange,
            bitrate: source.bitrate.map(Self.bitrateLabel),
            fileSize: source.size.map(Self.fileSizeLabel),
            audioTracks: streams.filter { $0.type == "Audio" }.map(Self.trackLabel),
            subtitleTracks: streams.filter { $0.type == "Subtitle" }.map(Self.trackLabel)
        )
        return details.isEmpty ? nil : details
    }

    /// Small call-out badges for the detail page's metadata row — resolution
    /// class, dynamic range, audio format, and accessibility tracks — shown
    /// where genres used to sit (see `InfoMetadataRow`). Independent of
    /// `technicalDetails` (which is display-formatted for the "Details"
    /// tab): a "4K"/"HD" badge needs a coarser bucket than that view's exact
    /// dimensions.
    ///
    /// Media with several audio tracks in different formats collapses each
    /// *family* to a single best badge rather than listing every track:
    /// Dolby Digital family is Atmos > DD+ > DD, DTS family is DTS-HD > DTS.
    /// Dolby TrueHD is the one exception — always shown alongside whichever
    /// Dolby Digital badge wins, since a TrueHD track often also carries an
    /// Atmos layer (e.g. Atmos + TrueHD + DTS-HD is a valid combination;
    /// Atmos + DD+ is not, since DD+ lost that family's priority contest).
    var metadataBadges: [String] {
        guard let source = dto.mediaSources?.first else { return [] }
        let streams = source.mediaStreams ?? []
        let videoStream = streams.first { $0.type == "Video" }
        let audioStreams = streams.filter { $0.type == "Audio" }
        let subtitleStreams = streams.filter { $0.type == "Subtitle" }

        var badges: [String] = []

        if let width = videoStream?.width, let commonName = Self.resolutionCommonName(width: width) {
            if commonName == "4K" {
                badges.append("4K")
            } else if ["1440p", "1080p", "720p"].contains(commonName) {
                badges.append("HD")
            }
        }

        if let dynamicRangeType = videoStream?.videoRangeType ?? videoStream?.videoRange {
            if dynamicRangeType.hasPrefix("DOVI") {
                badges.append("Dolby Vision")
            } else if dynamicRangeType == "HDR10" {
                badges.append("HDR10")
            } else if dynamicRangeType == "HDR10Plus" {
                badges.append("HDR10+")
            } else if dynamicRangeType == "HLG" {
                badges.append("HDR")
            }
        }

        if audioStreams.contains(where: { $0.audioSpatialFormat == "DolbyAtmos" }) {
            badges.append("Dolby Atmos")
        } else if Self.hasAudioCodec(audioStreams, "eac3") {
            badges.append("DD+")
        } else if Self.hasAudioCodec(audioStreams, "ac3") {
            badges.append("DD")
        }
        if Self.hasAudioCodec(audioStreams, "truehd") {
            badges.append("Dolby TrueHD")
        }

        if audioStreams.contains(where: Self.isDTSHD) {
            badges.append("DTS-HD")
        } else if Self.hasAudioCodec(audioStreams, "dts") {
            badges.append("DTS")
        }

        // "Not a forced track" — forced subtitles (foreign-dialogue-only)
        // don't count as closed captions; `nil` (unspecified) does.
        if subtitleStreams.contains(where: { $0.isForced != true }) {
            badges.append("CC")
        }

        if audioStreams.contains(where: Self.isAccessibilityAudioTrack) {
            badges.append("AD")
        }

        return badges
    }

    private static func hasAudioCodec(_ streams: [MediaStream], _ codec: String) -> Bool {
        streams.contains { ($0.codec ?? "").caseInsensitiveCompare(codec) == .orderedSame }
    }

    /// Jellyfin/ffprobe report every DTS variant with `codec == "dts"`; the
    /// HD/MA distinction only shows up in `profile` (e.g. "DTS-HD MA",
    /// "DTS-HD HRA" vs. plain "DTS" or no profile at all for core-only).
    private static func isDTSHD(_ stream: MediaStream) -> Bool {
        guard (stream.codec ?? "").caseInsensitiveCompare("dts") == .orderedSame else { return false }
        return (stream.profile ?? "").localizedCaseInsensitiveContains("dts-hd")
    }

    /// SDH is conventionally a *subtitle* accessibility convention, but an
    /// audio track can be tagged the same way for a described-audio/hearing
    /// -impaired mix — `isHearingImpaired` is the closest official signal
    /// Jellyfin exposes for that; text-matching the title/displayTitle
    /// catches tracks the server hasn't flagged that way.
    private static func isAccessibilityAudioTrack(_ stream: MediaStream) -> Bool {
        if stream.isHearingImpaired == true { return true }
        let haystack = [stream.title, stream.displayTitle].compactMap { $0 }.joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains("sdh")
            || haystack.localizedCaseInsensitiveContains("audio description")
            || haystack.localizedCaseInsensitiveContains("hard of hearing")
    }

    /// Cast and crew, in whatever order the server returns (Jellyfin
    /// typically lists billed actors first, then crew). Only populated when
    /// `people` was requested via `Fields=People`.
    ///
    /// `id` is synthesized from the person's own id *and* their position in
    /// the list, not `person.id` alone — the same real person can appear as
    /// more than one credit (e.g. an actor who also directed, or with two
    /// character roles), sharing the same underlying Guid across entries.
    /// `CastCrewGridView`'s `ForEach` needs a unique identifier per credit,
    /// not per person; duplicate ids there is exactly what caused the
    /// intermittent gaps/repeated cells this replaces (SwiftUI's diffing
    /// has no reliable way to tell two same-id cells apart while scrolling).
    var cast: [CastMember] {
        (dto.people ?? []).enumerated().map { index, person in
            CastMember(
                id: "\(person.id)-\(index)",
                name: person.name,
                // Actors/guest stars get a character name in `role`; crew
                // usually don't, so fall back to their job title (`type`).
                role: (person.role?.isEmpty ?? true) ? person.type : person.role,
                imageURL: person.primaryImageTag.flatMap {
                    images.url(itemID: person.id, imageType: "Primary", tag: $0, maxWidth: 200)
                }
            )
        }
    }

    // MARK: - Technical details formatting

    private static func resolutionLabel(width: Int, height: Int) -> String {
        let dimensions = "\(width)\u{00D7}\(height)"
        return resolutionCommonName(width: width).map { "\(dimensions) (\($0))" } ?? dimensions
    }

    /// Classifies by width, not height — a letterboxed, very-wide-aspect
    /// source (e.g. 2.39:1) has a correct width but a reduced height, which
    /// would misclassify a true 4K release as something lower-resolution if
    /// bucketed by height instead. Shared by `resolutionLabel` (the Details
    /// tab's exact dimensions) and `metadataBadges` (the coarser "4K"/"HD"
    /// badge).
    private static func resolutionCommonName(width: Int) -> String? {
        switch width {
        case 3840...:     "4K"
        case 2560..<3840: "1440p"
        case 1920..<2560: "1080p"
        case 1280..<1920: "720p"
        case 640..<1280:  "480p"
        default:          nil
        }
    }

    private static func friendlyVideoCodecName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "hevc", "h265": "H.265 (HEVC)"
        case "h264", "avc":  "H.264 (AVC)"
        case "av1":          "AV1"
        case "vp9":          "VP9"
        case "vp8":          "VP8"
        case "mpeg2video":   "MPEG-2"
        case "mpeg4":        "MPEG-4"
        case "vc1":          "VC-1"
        default:             raw.uppercased()
        }
    }

    /// Jellyfin's `VideoRangeType` is more specific than `VideoRange` when
    /// present (e.g. distinguishing Dolby Vision profiles that also carry an
    /// HDR10/HLG fallback layer); `technicalDetails` prefers it but falls
    /// back to the simpler `VideoRange` ("SDR"/"HDR"), which this also
    /// handles fine via the `default` case.
    private static func friendlyDynamicRangeName(_ raw: String) -> String {
        switch raw {
        case "DOVI":              "Dolby Vision"
        case "DOVIWithHDR10":     "Dolby Vision \u{00B7} HDR10"
        case "DOVIWithHDR10Plus": "Dolby Vision \u{00B7} HDR10+"
        case "DOVIWithHLG":       "Dolby Vision \u{00B7} HLG"
        case "DOVIWithSDR":       "Dolby Vision"
        case "HDR10Plus":         "HDR10+"
        default:                  raw
        }
    }

    /// Prefers the server-computed `displayTitle` (already a nicely
    /// formatted "English (AAC 5.1)"/"English (SRT - Forced)" string);
    /// falls back to assembling one from whatever fields are present for
    /// the rare case a stream doesn't have one.
    private static func trackLabel(for stream: MediaStream) -> String {
        if let displayTitle = stream.displayTitle, !displayTitle.isEmpty { return displayTitle }
        let parts = [stream.language, stream.codec?.uppercased()].compactMap { $0 }
        return parts.isEmpty ? "Track \(stream.index + 1)" : parts.joined(separator: " \u{00B7} ")
    }

    private static func bitrateLabel(_ bitsPerSecond: Int) -> String {
        String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
    }

    private static func fileSizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func imageURL(type: String = "Primary", maxWidth: Int? = nil) -> URL? {
        images.url(itemID: id, imageType: type, tag: dto.imageTags?[type], maxWidth: maxWidth)
    }

    var primaryImageURL: URL? { imageURL(type: "Primary", maxWidth: 500) }

    /// 16:9 "Thumb" image — episodes almost always have one (a still from
    /// the episode itself); series/seasons sometimes do too. `nil` when
    /// absent, rather than a URL that 404s — unlike `imageURL(type:)`
    /// (what `primaryImageURL` uses), which builds a URL regardless of
    /// whether `dto.imageTags` actually has an entry for the requested
    /// type, just omitting the `tag` query param when it doesn't. That's
    /// fine for `primaryImageURL` (every item is expected to have one), but
    /// would break `LandscapeMediaCard`'s `item.thumbImageURL ??
    /// item.primaryImageURL` fallback — a `Thumb`-less item would still get
    /// a (404ing) "URL" from the generic helper, so the `??` would never
    /// reach the poster fallback. Checking the tag directly, same as
    /// `logoImageURL` below, is what makes that fallback real.
    var thumbImageURL: URL? {
        guard let tag = dto.imageTags?["Thumb"] else { return nil }
        return images.url(itemID: id, imageType: "Thumb", tag: tag, maxWidth: 500)
    }

    /// Whether this item's rail tile should use the landscape 16:9 "Thumb"
    /// treatment (`LandscapeMediaCard`) rather than the portrait poster one
    /// (`PosterCard`, still used for movies, box sets, and everything else)
    /// — series/episodes read better as a still-frame thumbnail than a
    /// poster, and episodes in particular often don't have compelling
    /// poster art at all. See `MediaRailView`, the only place this is
    /// consulted — kept as a `MediaItem` property rather than inline in
    /// that view since it's a display-shaping decision about the item
    /// itself, same as `railTitle`/`railSubtitle` below.
    var usesLandscapeRailTile: Bool {
        switch dto.type {
        case .series, .episode: return true
        default: return false
        }
    }

    /// Own logo if this item has one; otherwise the nearest ancestor's
    /// (e.g. an episode falls back to its Season's logo, then its Series').
    /// `nil` — rather than a URL that 404s — when nothing in the hierarchy
    /// has one, so callers can fall back to a title text treatment instead.
    var logoImageURL: URL? {
        if let tag = dto.imageTags?["Logo"] {
            return images.url(itemID: id, imageType: "Logo", tag: tag, maxWidth: 600)
        }
        if let parentID = dto.parentLogoItemId, let tag = dto.parentLogoImageTag {
            return images.url(itemID: parentID, imageType: "Logo", tag: tag, maxWidth: 600)
        }
        return nil
    }

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
