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
    var frameRate: String?
    var dynamicRange: String?
    var bitrate: String?
    /// VoiceOver counterpart to `bitrate` — "X.X megabits per second"
    /// instead of "X.X Mbps", which reads letter by letter ("M B P S")
    /// rather than as a word. `nil` exactly when `bitrate` is.
    var bitrateAccessibilityText: String?
    var fileSize: String?
    /// VoiceOver counterpart to `fileSize` — see `bitrateAccessibilityText`'s
    /// doc comment for the same reasoning, applied to "GB"/"MB"/etc.
    /// instead of "Mbps". `nil` exactly when `fileSize` is.
    var fileSizeAccessibilityText: String?
    var audioTracks: [String]
    var subtitleTracks: [String]

    var isEmpty: Bool {
        container == nil && videoCodec == nil && resolution == nil && frameRate == nil
            && dynamicRange == nil && bitrate == nil && fileSize == nil && audioTracks.isEmpty
            && subtitleTracks.isEmpty
    }
}

/// One entry in the Details tab's version picker — see
/// `MediaItem.mediaVersions`.
struct MediaVersion: Identifiable, Hashable {
    let id: String
    let label: String
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
    /// The marketing tagline (e.g. "Some assembly required."), shown above
    /// the synopsis on the About tab. Jellyfin models this as an array
    /// (`Taglines`) but populates at most one for movies/shows in practice
    /// — first non-empty entry, `nil` if there isn't one. Only present when
    /// fetched via `Fields=Taglines` (see `JellyfinAPIClient.detailFields`
    /// — the detail page's own item fetch, not rail/list fetches, where a
    /// tagline is never shown and not worth the extra payload).
    var tagline: String? { dto.taglines?.first { !$0.isEmpty } }
    var kind: BaseItemKind { dto.type }
    /// AUDIO SUPPRESSION: see `BaseItemDto.isAudioContent`'s doc comment.
    var isAudioContent: Bool { dto.isAudioContent }
    var genres: [String] { dto.genres ?? [] }
    var studios: [String] { dto.studios?.map(\.name) ?? [] }
    var ageRating: String? { dto.officialRating }
    var communityRating: Double? { dto.communityRating }
    /// The decade this item's `productionYear` falls in, as its start year
    /// (e.g. `2010` for a 2016 release) — `CollectionGridView`'s Decade
    /// filter groups on this. `nil` when there's no production year to
    /// bucket. A start year rather than an already-formatted "2010s"
    /// string: that's just number/date formatting, same category as
    /// `yearText` below, done at the view layer instead.
    var decade: Int? {
        guard let year = dto.productionYear else { return nil }
        return (year / 10) * 10
    }
    /// Present on library "views" (e.g. `"movies"`, `"tvshows"`,
    /// `"boxsets"`) returned by `/Users/{id}/Views` — see
    /// `libraryContentItemTypes` for what this is actually used for.
    var collectionType: String? { dto.collectionType }
    /// AUDIO SUPPRESSION: true only for a Music library (`collectionType ==
    /// "music"`) — deliberately not `"musicvideos"`, which holds real
    /// playable video files. `HomeViewModel` filters this out of
    /// `libraries` before publishing, since `/Users/{id}/Views` has no
    /// server-side type filter to do it for us. Delete once Dionysus
    /// Player supports browsing a Music library.
    var isAudioLibrary: Bool { collectionType == JellyfinCollectionType.music }

    /// For a library item (one of `HomeViewModel.libraries`), the item
    /// type(s) a query scoped to it (`LibraryRailView`'s card tap) should
    /// restrict itself to — e.g. `["Series"]` for a Shows library. Without
    /// this, a recursive `/Items?ParentId=` walk returns *everything*
    /// nested under the library, not just its top-level items: a Shows
    /// library would mix every Season and Episode in alongside each
    /// Series, a Collections library would pull in every Movie/Series
    /// inside each BoxSet too, and (confirmed live) a Playlists library
    /// without this would pull in every member item of every playlist
    /// flattened in alongside the playlists themselves. Empty (no
    /// restriction) for library types this doesn't apply to (Music, ...)
    /// or for anything that isn't a library at all (`collectionType ==
    /// nil`).
    var libraryContentItemTypes: [String] {
        switch collectionType {
        case JellyfinCollectionType.movies: ["Movie"]
        case JellyfinCollectionType.tvShows: ["Series"]
        case JellyfinCollectionType.boxSets: ["BoxSet"]
        case JellyfinCollectionType.playlists: ["Playlist"]
        default: []
        }
    }

    // `yearText`/`durationText`/`episodeLabel`/`railSubtitle` below, plus
    // `resolutionCommonName`/`friendlyVideoCodecName`/
    // `friendlyDynamicRangeName`/`frameRateLabel`/`bitrateLabel` further down, are
    // deliberately left as plain (non-localized) string assembly: they're
    // either numeric/date formatting (years, durations, "S1:E4") or
    // industry-standard technical terms conventionally shown untranslated
    // (codec names, HDR formats) — same category as `metadataBadges`
    // (`InfoMetadataRow.swift`) and the player's timecodes
    // (`PlayerControlsOverlay.swift`). `trackLabel`'s "Track N" fallback
    // below is the one genuine natural-language string in this file, and is
    // localized.

    /// e.g. "2019" for a movie, "2019–2021" or "2019–" (still airing, best
    /// guess since we don't yet read Jellyfin's `Status` field) for a series.
    /// A season/series only ever has this coarser year-or-range to show —
    /// see `episodeAirDateText`/`metadataDateText` for an individual
    /// episode's exact date instead.
    var yearText: String? {
        guard let year = dto.productionYear else { return nil }
        guard dto.type == .series else { return String(year) }

        if let endDate = dto.endDate {
            let endYear = Calendar.current.component(.year, from: endDate)
            return endYear == year ? String(year) : "\(year)\u{2013}\(endYear)"
        }
        return "\(year)\u{2013}"
    }

    /// An episode's exact release date, e.g. "1 Aug 2026" — unlike a show
    /// or season, a single episode has one specific air date worth spelling
    /// out in full rather than collapsing to just its year. `nil` for
    /// anything that isn't an episode, or an episode with no
    /// `premiereDate` (e.g. not yet aired). Used by `metadataDateText`
    /// (the detail page's metadata row) and directly by
    /// `SeasonEpisodeList`'s own per-episode row.
    var episodeAirDateText: String? {
        guard dto.type == .episode, let date = dto.premiereDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// Whichever of `yearText`/`episodeAirDateText` is the right level of
    /// detail for this item's kind — an episode's exact date, everything
    /// else's coarser year/year-range. `InfoMetadataRow` is the one call
    /// site (shared across every detail-page kind: Movie, Show/Season, and
    /// Show-content-as-Episode — see `ShowDetailView`'s own doc comment),
    /// so the branching lives here instead of being repeated at each of
    /// them.
    var metadataDateText: String? {
        dto.type == .episode ? episodeAirDateText : yearText
    }

    var durationText: String? {
        guard let totalMinutes = durationTotalMinutes else { return nil }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Same duration as `durationText`, worded out for VoiceOver — confirmed
    /// live (real device, VoiceOver on) that the compact "1h 32m" gets
    /// misheard outright: VoiceOver reads "m" as the metric unit, producing
    /// "One H Thirty Meters," not "one hour thirty minutes."
    /// `DateComponentsFormatter`'s `.full` style spells the units out and
    /// gets pluralization/localization right ("1 hour" vs. "2 hours") in a
    /// way hand-rolled string interpolation wouldn't.
    var durationAccessibilityText: String? {
        guard let totalMinutes = durationTotalMinutes else { return nil }
        return Self.spokenDuration(totalMinutes: totalMinutes)
    }

    private var durationTotalMinutes: Int? {
        guard let ticks = dto.runTimeTicks, ticks > 0 else { return nil }
        return Int(ticks / 10_000_000 / 60)
    }

    /// `resumePositionSeconds`, worded out for VoiceOver — same
    /// `spokenDuration(totalMinutes:)` `durationAccessibilityText` uses,
    /// just from a different source value (elapsed time into the item, not
    /// its total runtime) — e.g. "Resume S19:E6 from 33 minutes" at an
    /// episode-list row's own call site. `nil` whenever there's nothing to
    /// resume from.
    var resumePositionAccessibilityText: String? {
        guard let resumePositionSeconds, resumePositionSeconds > 0 else { return nil }
        return Self.spokenDuration(totalMinutes: Int(resumePositionSeconds / 60))
    }

    /// Shared by `durationAccessibilityText`/`resumePositionAccessibilityText`
    /// — see the former's own doc comment for why this needs
    /// `DateComponentsFormatter` rather than hand-rolled interpolation.
    private static func spokenDuration(totalMinutes: Int) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = totalMinutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(totalMinutes * 60))
    }

    /// e.g. "S1:E4" for an episode.
    var episodeLabel: String? {
        guard dto.type == .episode, let season = dto.parentIndexNumber, let episode = dto.indexNumber else {
            return nil
        }
        return "S\(season):E\(episode)"
    }

    /// `episodeLabel`, worded out for VoiceOver — "season 1 episode 4"
    /// instead of letters/colon, which would either be spelled out
    /// letter-by-letter or misread outright (same category of problem as
    /// `durationAccessibilityText`'s "1h 32m"). `nil` under the same
    /// conditions `episodeLabel` is.
    var episodeLabelAccessibilityText: String? {
        guard dto.type == .episode, let season = dto.parentIndexNumber, let episode = dto.indexNumber else {
            return nil
        }
        return String(localized: "season \(season) episode \(episode)")
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

    /// What a rail/grid card's `NavigationLink` reads aloud as a whole —
    /// `railTitle` plus `railSubtitle` (when there is one), e.g. "The Super
    /// Mario Bros. Movie, 2023 · 1h 32m". Used instead of leaning on
    /// SwiftUI's automatic per-child accessibility combination: cards mix
    /// an `AsyncRemoteImage` (no label of its own) with decorative status
    /// glyphs (favorite star, watched eye, in-progress bar) that would
    /// otherwise leak their own SF Symbol names into the combined label —
    /// see `PosterCard`/`LandscapeMediaCard`/`LibraryCard`/`HeroRailCard`,
    /// none of which had *any* accessibility label before this, confirmed
    /// via VoiceOver-style automation reading every one of them back as
    /// blank/"Unnamed".
    var accessibilityDescription: String {
        guard let railSubtitleAccessibilityText else { return railTitle }
        return "\(railTitle), \(railSubtitleAccessibilityText)"
    }

    /// Same composition as `railSubtitle`, but substituting
    /// `durationAccessibilityText` for `durationText` — see that property's
    /// own doc comment for why. Movies are the only `railSubtitle` case that
    /// embeds a duration at all (episode/series never do), so this only
    /// actually diverges from `railSubtitle` there.
    private var railSubtitleAccessibilityText: String? {
        guard dto.type == .movie else { return railSubtitle }
        let parts = [yearText, durationAccessibilityText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
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

    /// Changes exactly when the progress-bar/Play-vs-Resume fields do
    /// (`resumePositionSeconds`/`playedFraction`/`isPlayed`).
    ///
    /// Handed to `.id()` on `PlayResumeButtonRow`
    /// (`MovieDetailView`/`ShowDetailView`) to force a rebuild rather than
    /// an update. `MediaItem.==` alone should already be enough; this is
    /// deliberate redundancy on the one update that has silently regressed
    /// more than once. Rebuilding also resets that view's own `@State` (the
    /// version-choice prompt), which is fine — it should not survive a
    /// change of playback position anyway.
    var playbackProgressIdentity: String {
        "\(dto.userData?.playbackPositionTicks ?? -1)-\(dto.userData?.playedPercentage ?? -1)-\(dto.userData?.played ?? false)"
    }

    /// `id` plus `playbackProgressIdentity`, for `MediaRailView`'s
    /// `ForEach(rail.items, id:)` — a changed resume position becomes a
    /// different row *identity*, which SwiftUI must act on, rather than a
    /// different row value it may compare its way out of re-rendering.
    ///
    /// Same deliberate redundancy as `playbackProgressIdentity`, and no
    /// more expensive than the per-card `.id()` it replaced.
    var railRowIdentity: String { "\(id)-\(playbackProgressIdentity)" }

    var isFavorite: Bool { dto.userData?.isFavorite ?? false }

    /// True when the user has started but not finished this item. For movies,
    /// that's a mid-playback position; for shows, some-but-not-all episodes
    /// watched (Jellyfin surfaces both as `playedPercentage`).
    var isPartWatched: Bool {
        guard !isPlayed, let fraction = playedFraction else { return false }
        return fraction > 0 && fraction < 1
    }

    /// Container/codec/resolution/dynamic-range summary plus per-track audio
    /// and subtitle lists, for the detail page's "Details" tab's default
    /// (first/highest-quality) version. `nil` when there's no media source
    /// at all (e.g. viewing a Series, which has no file of its own — only
    /// its episodes do). See `technicalDetails(forVersion:)` for a specific
    /// `mediaVersions` entry instead — this is exactly that with `nil`.
    var technicalDetails: TechnicalDetails? { technicalDetails(forVersion: nil) }

    /// Same as `technicalDetails`, but for one specific version out of
    /// `mediaVersions` (`versionID` is a `MediaVersion.id`, i.e. a
    /// `MediaSourceInfo.id`) — what `TechnicalDetailsView`'s version picker
    /// switches between. `nil` falls back to the first/default source, same
    /// as the no-argument `technicalDetails`; an unrecognized `versionID`
    /// (shouldn't happen — the picker only ever offers ids from
    /// `mediaVersions`) does too, rather than showing nothing.
    func technicalDetails(forVersion versionID: String?) -> TechnicalDetails? {
        guard let source = Self.mediaSource(in: dto, matching: versionID) else { return nil }
        let streams = source.mediaStreams ?? []
        let videoStream = streams.first { $0.type == "Video" }

        var resolution: String?
        if let width = videoStream?.width, let height = videoStream?.height {
            resolution = Self.resolutionLabel(width: width, height: height)
        }
        let dynamicRange = (videoStream?.videoRangeType ?? videoStream?.videoRange)
            .flatMap { $0.isEmpty || $0 == "Unknown" ? nil : Self.friendlyDynamicRangeName($0) }
        let frameRate = (videoStream?.realFrameRate ?? videoStream?.averageFrameRate)
            .map(Self.frameRateLabel)

        let details = TechnicalDetails(
            container: source.container?.uppercased(),
            videoCodec: videoStream?.codec.map(Self.friendlyVideoCodecName),
            resolution: resolution,
            frameRate: frameRate,
            dynamicRange: dynamicRange,
            bitrate: source.bitrate.map(Self.bitrateLabel),
            bitrateAccessibilityText: source.bitrate.map(Self.bitrateAccessibilityLabel),
            fileSize: source.size.map(Self.fileSizeLabel),
            fileSizeAccessibilityText: source.size.map(Self.fileSizeAccessibilityLabel),
            audioTracks: streams.filter { $0.type == "Audio" }.map(Self.trackLabel),
            subtitleTracks: streams.filter { $0.type == "Subtitle" }.map(Self.trackLabel)
        )
        return details.isEmpty ? nil : details
    }

    /// Every distinct media file backing this item, when there's more than
    /// one — Jellyfin calls these an item's "versions". These aren't always
    /// a technical variant (a 4K UHD remux alongside a separate 1080p
    /// encode) — they're just as often an edition the uploader chose to
    /// keep alongside the original (a "Director's Cut", "Extended
    /// Version", "Black and White" cut, etc.) with identical or
    /// near-identical technical specs, all listed in `mediaSources`. Empty
    /// whenever there's nothing to choose between: no media file at all
    /// (Series/Season), or the overwhelmingly common single-version case —
    /// `TechnicalDetailsView`'s version picker only shows up when this has
    /// more than one entry, per its call site.
    ///
    /// Ordered exactly as the server returns `mediaSources` — Jellyfin
    /// itself puts the version it'd pick for direct play first, so the
    /// first entry here doubles as "the default" (`technicalDetails`/
    /// `metadataBadges` both implicitly use it).
    var mediaVersions: [MediaVersion] {
        guard let sources = dto.mediaSources, sources.count > 1 else { return [] }
        // The filename-derived edition name (see `editionLabel`) takes
        // priority over the resolution/dynamic-range bucket whenever
        // Jellyfin's naming convention lets us recover one — it's what the
        // uploader actually called this version, which a technical bucket
        // can't express (and, for a same-spec alternate cut, can't even
        // distinguish from the original at all). The base/canonical version
        // itself is always labeled "Original" in that case, rather than
        // guessing at a resolution/HDR label for it — see the comment below.
        let canonicalName = Self.canonicalSourceName(sources)
        var seenLabels: Set<String> = []
        return sources.enumerated().map { index, source in
            var label: String
            if let canonicalName {
                // We've confirmed this item follows Jellyfin's naming
                // convention (every source's name either matches
                // `canonicalName` or extends it), so we know which source
                // is the base one — but not what dimension the *other*
                // versions differ by, since that's whatever the uploader
                // chose to call them. Labeling the base version by a
                // resolution/HDR guess would imply that's the convention in
                // play even when it isn't (e.g. an "Extended Version"
                // alongside an identically-encoded original); "Original" is
                // the one label that's never a wrong assumption.
                label = Self.editionLabel(for: source, canonicalName: canonicalName)
                    ?? String(localized: "Original")
            } else {
                label = Self.versionLabel(for: source, fallbackIndex: index)
            }
            // Disambiguate the rare case two versions land on the same
            // coarse label (e.g. two 1080p SDR encodes) — better than
            // silently offering two menu entries a user can't tell apart.
            if !seenLabels.insert(label).inserted {
                label += " (\(index + 1))"
            }
            return MediaVersion(id: source.id ?? String(index), label: label)
        }
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

        if let dynamicRangeType = videoStream?.videoRangeType ?? videoStream?.videoRange,
           let badge = Self.dynamicRangeBadge(dynamicRangeType) {
            badges.append(badge)
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

    /// `mediaVersions`' fallback labeling, used whenever `editionLabel`
    /// can't recover a filename-derived edition name (Jellyfin's naming
    /// convention wasn't followed, or this genuinely is just a plain
    /// technical alternate with no edition of its own). Coarse
    /// resolution+dynamic-range label for one entry, e.g. "4K HDR10" or
    /// "1080p" — deliberately the same coarse buckets `metadataBadges`
    /// uses (via `dynamicRangeBadge`/`resolutionCommonName` below), not
    /// `technicalDetails`' exact dimensions/format string, since this needs
    /// to read at a glance in a picker, not document the file precisely.
    /// Falls back to the server's own (raw, filename-ish)
    /// `MediaSourceInfo.name` when neither a recognized resolution nor
    /// dynamic range is available to build a label from, and finally to a
    /// generic "Version N" if even that's missing.
    private static func versionLabel(for source: MediaSourceInfo, fallbackIndex: Int) -> String {
        let videoStream = (source.mediaStreams ?? []).first { $0.type == "Video" }
        var parts: [String] = []
        if let width = videoStream?.width, let commonName = resolutionCommonName(width: width) {
            parts.append(commonName)
        }
        if let dynamicRangeType = videoStream?.videoRangeType ?? videoStream?.videoRange,
           let badge = dynamicRangeBadge(dynamicRangeType) {
            parts.append(badge)
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if let name = source.name, !name.isEmpty { return name }
        return String(localized: "Version \(fallbackIndex + 1)")
    }

    /// The base filename every alternate version's `MediaSourceInfo.name`
    /// is expected to extend, per Jellyfin's own multi-version naming
    /// convention: alternate cuts live alongside the primary file as
    /// `<primary file name> - <edition name>.ext` (e.g. a theatrical cut
    /// named `Movie - [Bluray-2160p]-GROUP.mkv` and an extended cut named
    /// `Movie - [Bluray-2160p]-GROUP - Extended Version.mkv`).
    /// `MediaSourceInfo.name` is the filename-derived stem the server
    /// already computes — confirmed against a real multi-version item on a
    /// test server, where two sources' raw `name`s were identical except
    /// the alternate had `" - 1080p"` appended — so the canonical source is
    /// whichever one is a literal prefix of every other source's name.
    /// `nil` when that relationship doesn't hold (a name missing, or this
    /// set of versions simply doesn't follow the convention); callers
    /// should fall back to `versionLabel`'s resolution/dynamic-range
    /// bucketing in that case.
    ///
    /// Deliberately not "split every name on ` - ` and take the last
    /// piece": real filenames routinely contain unrelated dashes of their
    /// own (release-group tags like `[Bluray-2160p]` or `x265]-GROUP`), so
    /// only a prefix comparison against a known canonical name can isolate
    /// the actual edition suffix reliably.
    private static func canonicalSourceName(_ sources: [MediaSourceInfo]) -> String? {
        let names = sources.map { $0.name ?? "" }
        guard sources.count > 1, names.allSatisfy({ !$0.isEmpty }) else { return nil }
        return names.first { candidate in
            names.allSatisfy { $0 == candidate || $0.hasPrefix(candidate + " - ") }
        }
    }

    /// The edition name Jellyfin's filename convention encodes for one
    /// version relative to `canonicalName` (see `canonicalSourceName`
    /// above) — e.g. `"Extended Version"`, `"1080p"`, `"Black and White"` —
    /// verbatim, exactly as the uploader named it. `nil` for the canonical
    /// version itself (nothing to show) or when this source's name doesn't
    /// extend `canonicalName` at all.
    private static func editionLabel(for source: MediaSourceInfo, canonicalName: String?) -> String? {
        guard let canonicalName, let name = source.name, name != canonicalName else { return nil }
        let prefix = canonicalName + " - "
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = String(name.dropFirst(prefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    /// Shared by `metadataBadges` (resolution/dynamic-range badges on the
    /// detail page's second metadata line) and `versionLabel` (the version
    /// picker's per-entry label) — both want the same coarse "Dolby
    /// Vision"/"HDR10"/"HDR10+"/"HDR" buckets from Jellyfin's raw
    /// `VideoRangeType`/`VideoRange`, `nil` for plain SDR (no badge/word
    /// worth showing).
    private static func dynamicRangeBadge(_ dynamicRangeType: String) -> String? {
        if dynamicRangeType.hasPrefix("DOVI") { return "Dolby Vision" }
        switch dynamicRangeType {
        case "HDR10": return "HDR10"
        case "HDR10Plus": return "HDR10+"
        case "HLG": return "HDR"
        default: return nil
        }
    }

    /// Looks up a specific `mediaSources` entry by id, falling back to the
    /// first/default one when `versionID` is `nil` or doesn't match
    /// anything — split out of `technicalDetails(forVersion:)` as its own
    /// function (rather than an inline `flatMap`/`??` one-liner) because
    /// that inline form made the type-checker choke ("unable to type-check
    /// this expression in reasonable time").
    private static func mediaSource(in dto: BaseItemDto, matching versionID: String?) -> MediaSourceInfo? {
        guard let sources = dto.mediaSources else { return nil }
        if let versionID, let match = sources.first(where: { $0.id == versionID }) {
            return match
        }
        return sources.first
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

    /// Not `private` — `DownloadedTechnicalDetailsView`'s Details tab reuses
    /// this exact "dimensions (common name)" formatting for a download's own
    /// resolution, so the two Details tabs never drift into showing the
    /// same resolution two different ways.
    static func resolutionLabel(width: Int, height: Int) -> String {
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
        return parts.isEmpty ? String(localized: "Track \(stream.index + 1)") : parts.joined(separator: " \u{00B7} ")
    }

    /// e.g. "23.976 fps", "29.97 fps", "60 fps" — up to three decimal
    /// places, trimmed of trailing zeros (and the decimal point itself for
    /// whole numbers like a clean 24 or 60).
    private static func frameRateLabel(_ fps: Double) -> String {
        var formatted = String(format: "%.3f", fps)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return "\(formatted) fps"
    }

    private static func bitrateLabel(_ bitsPerSecond: Int) -> String {
        String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
    }

    /// `bitrateLabel`'s VoiceOver counterpart — "Mbps" read letter by
    /// letter ("M B P S") rather than as a word, same class of bug as
    /// `fileSizeAccessibilityLabel` below.
    private static func bitrateAccessibilityLabel(_ bitsPerSecond: Int) -> String {
        let mbps = String(format: "%.1f", Double(bitsPerSecond) / 1_000_000)
        return String(localized: "\(mbps) megabits per second")
    }

    private static func fileSizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `fileSizeLabel`'s VoiceOver counterpart — visually "2.44 GB", but
    /// read by VoiceOver as "two dot forty-four G B" letter by letter
    /// rather than a real unit. Reuses `fileSizeLabel`'s own formatter
    /// output rather than reimplementing its unit-selection/rounding, so
    /// the two can never drift out of agreement — just spells out
    /// whatever unit it landed on. Falls back to the original text
    /// unchanged for a unit this doesn't recognize (shouldn't happen —
    /// `ByteCountFormatter` only ever emits bytes/KB/MB/GB/TB/PB — but a
    /// silently-wrong readout would be worse than an unexpanded one).
    private static func fileSizeAccessibilityLabel(_ bytes: Int64) -> String {
        let text = fileSizeLabel(bytes)
        guard let spaceIndex = text.lastIndex(of: " ") else { return text }
        let number = text[..<spaceIndex]
        let unit = text[text.index(after: spaceIndex)...]
        let spokenUnit: String?
        switch unit {
        case "byte", "bytes": spokenUnit = String(localized: "bytes")
        case "KB": spokenUnit = String(localized: "kilobytes")
        case "MB": spokenUnit = String(localized: "megabytes")
        case "GB": spokenUnit = String(localized: "gigabytes")
        case "TB": spokenUnit = String(localized: "terabytes")
        case "PB": spokenUnit = String(localized: "petabytes")
        default: spokenUnit = nil
        }
        guard let spokenUnit else { return text }
        return "\(number) \(spokenUnit)"
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

    /// A copy with `resumePositionSeconds`/`playedFraction` overwritten to
    /// reflect a just-closed playback session's final position — see
    /// `AssetDetailViewModel.applyOptimisticPlaybackPosition(_:)` for why
    /// this exists (a way to reflect a known-correct value immediately,
    /// rather than waiting on a server round-trip to confirm it). Copies
    /// `dto` and overwrites only its `userData`'s position fields, leaving
    /// everything else (including `played`, deliberately — see that
    /// method's own doc comment) untouched; a no-op (`self`, unchanged) for
    /// a zero/negative duration, which can't produce a meaningful fraction.
    func withOptimisticPlaybackPosition(seconds: TimeInterval, duration: TimeInterval) -> MediaItem {
        guard duration > 0 else { return self }
        var newDto = dto
        var userData = newDto.userData ?? UserItemDataDto()
        userData.playbackPositionTicks = Int64(seconds * 10_000_000)
        userData.playedPercentage = min(100, max(0, (seconds / duration) * 100))
        newDto.userData = userData
        return MediaItem(dto: newDto, images: images)
    }

    /// A copy with `isFavorite`/`isPlayed` overwritten immediately — the
    /// `withOptimisticPlaybackPosition`'s sibling for the other two
    /// server-async `userData` fields. See
    /// `AssetDetailViewModel.applyOptimisticFavoriteWatched(itemID:favorite:watched:)`
    /// for why this exists: confirmed live, a favorite/watched write that
    /// returned success immediately didn't actually commit server-side for
    /// several *minutes* on a real server, well past what this app's
    /// confirmation poll waits out — without applying the known-good value
    /// right away, the toolbar button looked like a second tap did nothing
    /// at all. `favorite`/`watched` each default to `nil` (leave that field
    /// as-is) so a caller changing only one doesn't need to know the
    /// other's current value.
    func withOptimisticFavoriteWatched(favorite: Bool? = nil, watched: Bool? = nil) -> MediaItem {
        guard favorite != nil || watched != nil else { return self }
        var newDto = dto
        var userData = newDto.userData ?? UserItemDataDto()
        if let favorite { userData.isFavorite = favorite }
        if let watched { userData.played = watched }
        newDto.userData = userData
        return MediaItem(dto: newDto, images: images)
    }
}

extension MediaItem: Hashable {
    /// Forwards to `BaseItemDto`'s structural equality — every field, not
    /// just `id`. **Do not narrow this to an id comparison.**
    ///
    /// SwiftUI prefers a stored property's own `==` over its internal
    /// comparison when deciding whether a view changed, and `MediaItem` is
    /// the stored property of essentially every view here (`PosterCard`,
    /// `PlayResumeButtonRow`, `InfoMetadataRow`, `DetailTabsView`, ...)
    /// while `[MediaItem]` is what `ForEach(rail.items)` diffs on. An
    /// id-only `==` is therefore a promise that nothing under a stable id
    /// is ever worth repainting — false for `userData` after playback, and
    /// for `mediaSources`/`people` when `AssetDetailViewModel` swaps its
    /// preloaded item for the full fetch. Both froze views on their
    /// first-rendered values.
    ///
    /// `images` is not compared: an `ImageURLBuilder` snapshot of session
    /// config, identical for every item and never a reason to repaint.
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.dto == rhs.dto }

    /// Id-only on purpose, even though `==` is structural — the legal
    /// direction for the `Hashable` contract, and what keeps id-keyed
    /// lookups (`AppRoute`'s synthesized hashing for
    /// `navigationDestination`, any `Set`/dictionary use) treating one
    /// server item as one entry rather than one per revision of its fields.
    func hash(into hasher: inout Hasher) { hasher.combine(dto.id) }
}
