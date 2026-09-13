import Foundation

/// A cast/crew credit ready for display — see `MediaItem.cast`.
struct CastMember: Identifiable, Hashable {
    var id: String
    var name: String
    var role: String?
    var imageURL: URL?
}

/// Container, codec, resolution and dynamic-range summary plus per-track audio
/// and subtitle lists for a detail page's "Details" tab. Every field is already
/// display-formatted; views need no further conversion.
struct TechnicalDetails: Equatable {
    var container: String?
    var videoCodec: String?
    var resolution: String?
    var frameRate: String?
    var dynamicRange: String?
    var bitrate: String?
    /// VoiceOver counterpart to `bitrate`: "megabits per second" rather than
    /// "Mbps", which is read letter by letter. `nil` exactly when `bitrate` is.
    var bitrateAccessibilityText: String?
    var fileSize: String?
    /// VoiceOver counterpart to `fileSize`, spelling out "GB"/"MB". `nil`
    /// exactly when `fileSize` is.
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
    /// The marketing tagline shown above the synopsis on the About tab.
    /// Jellyfin models `Taglines` as an array but populates at most one, so
    /// this takes the first non-empty entry. Only populated by
    /// `JellyfinAPIClient.detailFields`, not by rail or list fetches.
    var tagline: String? { dto.taglines?.first { !$0.isEmpty } }
    var kind: BaseItemKind { dto.type }
    /// AUDIO SUPPRESSION: see `BaseItemDto.isAudioContent`'s doc comment.
    var isAudioContent: Bool { dto.isAudioContent }
    var genres: [String] { dto.genres ?? [] }
    var studios: [String] { dto.studios?.map(\.name) ?? [] }
    var ageRating: String? { dto.officialRating }
    var communityRating: Double? { dto.communityRating }
    /// The start year of this item's decade (`2010` for a 2016 release), which
    /// `CollectionGridView`'s Decade filter groups on. A number rather than a
    /// formatted "2010s" string, leaving that formatting to the view.
    var decade: Int? {
        guard let year = dto.productionYear else { return nil }
        return (year / 10) * 10
    }
    /// Present on library views (`"movies"`, `"tvshows"`, `"boxsets"`) from
    /// `/Users/{id}/Views`. See `libraryContentItemTypes`.
    var collectionType: String? { dto.collectionType }
    /// AUDIO SUPPRESSION: Music libraries only, not `"musicvideos"`, which
    /// holds playable video. `HomeViewModel` filters these out of `libraries`
    /// because `/Users/{id}/Views` has no server-side type filter. Delete once
    /// browsing a Music library is supported.
    var isAudioLibrary: Bool { collectionType == JellyfinCollectionType.music }

    /// The item types a query scoped to this library should restrict itself to.
    /// A recursive `/Items?ParentId=` walk otherwise returns everything nested
    /// under the library: a Shows library mixes in every Season and Episode, a
    /// Collections library every Movie and Series inside each BoxSet, and a
    /// Playlists library every member of every playlist. Empty for library
    /// types this doesn't apply to, and for non-libraries.
    var libraryContentItemTypes: [String] {
        switch collectionType {
        case JellyfinCollectionType.movies: ["Movie"]
        case JellyfinCollectionType.tvShows: ["Series"]
        case JellyfinCollectionType.boxSets: ["BoxSet"]
        case JellyfinCollectionType.playlists: ["Playlist"]
        default: []
        }
    }

    // The display strings below are unlocalized: they are numeric or date
    // formatting (years, durations, "S1:E4") or industry-standard technical
    // terms shown untranslated (codec names, HDR formats). `trackLabel`'s
    // "Track N" fallback is the one natural-language string here, and is
    // localized.

    /// "2019" for a movie, "2019–2021" or "2019–" for a series; the trailing
    /// dash is a guess, since Jellyfin's `Status` field isn't read yet. See
    /// `episodeAirDateText` for an individual episode's exact date.
    var yearText: String? {
        guard let year = dto.productionYear else { return nil }
        guard dto.type == .series else { return String(year) }

        if let endDate = dto.endDate {
            let endYear = Calendar.current.component(.year, from: endDate)
            return endYear == year ? String(year) : "\(year)\u{2013}\(endYear)"
        }
        return "\(year)\u{2013}"
    }

    /// An episode's exact air date ("1 Aug 2026"), worth spelling out where a
    /// show or season has only a year. `nil` for non-episodes and for an
    /// episode with no `premiereDate`.
    var episodeAirDateText: String? {
        guard dto.type == .episode, let date = dto.premiereDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// `yearText` or `episodeAirDateText`, whichever suits this item's kind.
    /// The branching lives here because `InfoMetadataRow` is shared across
    /// every detail-page kind.
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

    /// `durationText` worded out for VoiceOver, which reads the compact
    /// "1h 32m" as "One H Thirty Meters". `DateComponentsFormatter`'s `.full`
    /// style spells the units out and handles pluralization and localization.
    var durationAccessibilityText: String? {
        guard let totalMinutes = durationTotalMinutes else { return nil }
        return Self.spokenDuration(totalMinutes: totalMinutes)
    }

    private var durationTotalMinutes: Int? {
        guard let ticks = dto.runTimeTicks, ticks > 0 else { return nil }
        return Int(ticks / 10_000_000 / 60)
    }

    /// `resumePositionSeconds` worded out for VoiceOver, e.g. "Resume S19:E6
    /// from 33 minutes". `nil` when there is nothing to resume from.
    var resumePositionAccessibilityText: String? {
        guard let resumePositionSeconds, resumePositionSeconds > 0 else { return nil }
        return Self.spokenDuration(totalMinutes: Int(resumePositionSeconds / 60))
    }

    /// Shared by `durationAccessibilityText` and
    /// `resumePositionAccessibilityText`.
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

    /// `episodeLabel` worded out for VoiceOver: "season 1 episode 4" rather
    /// than letters and a colon, which are spelled out or misread.
    var episodeLabelAccessibilityText: String? {
        guard dto.type == .episode, let season = dto.parentIndexNumber, let episode = dto.indexNumber else {
            return nil
        }
        return String(localized: "season \(season) episode \(episode)")
    }

    /// First line under a poster card. Episodes show their series name, so
    /// Continue Watching reads as show titles rather than episode titles.
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

    /// What a card's `NavigationLink` reads aloud: `railTitle` plus
    /// `railSubtitle`. Set explicitly rather than relying on SwiftUI's
    /// per-child combination, which would leak the SF Symbol names of a card's
    /// decorative status glyphs (favorite star, watched eye, progress bar) into
    /// the label alongside an image that has none.
    var accessibilityDescription: String {
        guard let railSubtitleAccessibilityText else { return railTitle }
        return "\(railTitle), \(railSubtitleAccessibilityText)"
    }

    /// `railSubtitle` with `durationAccessibilityText` in place of
    /// `durationText`. Only movies embed a duration, so only they diverge.
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
        // `playedPercentage` can lag a freshly-written
        // `playbackPositionTicks`, so compute the ratio when both are present.
        if let positionTicks = dto.userData?.playbackPositionTicks, positionTicks > 0,
           let runTimeTicks = dto.runTimeTicks, runTimeTicks > 0 {
            return Double(positionTicks) / Double(runTimeTicks)
        }
        return nil
    }

    var isPlayed: Bool { dto.userData?.played ?? false }

    /// Changes exactly when `resumePositionSeconds`, `playedFraction` or
    /// `isPlayed` do.
    ///
    /// Handed to `.id()` on `PlayResumeButtonRow` to force a rebuild rather
    /// than an update. `MediaItem.==` should suffice; this is redundancy on an
    /// update that has regressed silently more than once. The rebuild also
    /// resets that view's version-choice prompt, which shouldn't survive a
    /// change of playback position anyway.
    var playbackProgressIdentity: String {
        "\(dto.userData?.playbackPositionTicks ?? -1)-\(dto.userData?.playedPercentage ?? -1)-\(dto.userData?.played ?? false)"
    }

    /// `id` plus `playbackProgressIdentity`, for `MediaRailView`'s
    /// `ForEach(rail.items, id:)`: a changed resume position becomes a different
    /// row identity, which SwiftUI must act on, rather than a different value it
    /// may compare its way out of re-rendering.
    var railRowIdentity: String { "\(id)-\(playbackProgressIdentity)" }

    var isFavorite: Bool { dto.userData?.isFavorite ?? false }

    /// Whether this user may delete this item, gating `AssetActionsButton`'s
    /// delete affordance.
    ///
    /// `false` when absent, which is the common case: only
    /// `JellyfinAPIClient.detailFields` requests `CanDelete`, so a `MediaItem`
    /// from a rail or grid reports `false` until the detail fetch lands. That is
    /// the right direction to fail in — a button appearing late is cosmetic,
    /// one appearing for someone who can't delete is a broken promise, and an
    /// expensive one given Jellyfin answers permission-denied with 401.
    var canDelete: Bool { dto.canDelete ?? false }

    /// This item's identity within the playlist it was fetched from; `nil`
    /// outside `JellyfinAPIClient.playlistItems`' response. Keys
    /// `PlaylistItemList`'s `ForEach`, since `id` isn't unique per row when an
    /// item appears twice, and supplies `removePlaylistItems`' `entryIds`.
    var playlistItemID: String? { dto.playlistItemId }

    /// The parent Series' id for a Season or Episode. Distinct from
    /// `AssetDetailViewModel.seriesID`, which is that view model's resolved page
    /// context; this is the field the server put on this item, and all a caller
    /// holding a lone `MediaItem` has to work from.
    var seriesID: String? { dto.seriesId }

    /// Total episodes beneath a Series or Season, for the delete confirmation's
    /// "will delete all {n} episodes". `nil` unless `Fields=RecursiveItemCount`
    /// was requested, which the copy handles with count-free wording.
    ///
    /// Not `dto.childCount`, which on a Series counts seasons.
    var episodeCount: Int? { dto.recursiveItemCount }

    /// Started but not finished: a mid-playback position for a movie, some but
    /// not all episodes watched for a show. Jellyfin reports both as
    /// `playedPercentage`.
    var isPartWatched: Bool {
        guard !isPlayed, let fraction = playedFraction else { return false }
        return fraction > 0 && fraction < 1
    }

    /// The Details tab's summary for the default (first, highest-quality)
    /// version. `nil` when there is no media source, as on a Series, which has
    /// no file of its own. Equivalent to `technicalDetails(forVersion: nil)`.
    var technicalDetails: TechnicalDetails? { technicalDetails(forVersion: nil) }

    /// `technicalDetails` for one `mediaVersions` entry, which
    /// `TechnicalDetailsView`'s version picker switches between. A `nil` or
    /// unrecognized `versionID` falls back to the first source rather than
    /// showing nothing.
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

    /// Every media file backing this item when there is more than one —
    /// Jellyfin's "versions". Often a technical variant (a 4K remux beside a
    /// 1080p encode), but just as often an edition with near-identical specs (a
    /// Director's Cut, an Extended Version). Empty when there is nothing to
    /// choose between: no media file at all, or the common single-version case.
    ///
    /// Ordered as the server returns `mediaSources`, which puts the version it
    /// would pick for direct play first, so the first entry is the default.
    var mediaVersions: [MediaVersion] {
        guard let sources = dto.mediaSources, sources.count > 1 else { return [] }
        // A filename-derived edition name (`editionLabel`) outranks the
        // resolution/dynamic-range bucket: it is what the uploader called this
        // version, which a technical bucket can't express and, for a same-spec
        // alternate cut, can't even distinguish from the original.
        let canonicalName = Self.canonicalSourceName(sources)
        var seenLabels: Set<String> = []
        return sources.enumerated().map { index, source in
            var label: String
            if let canonicalName {
                // The naming convention identifies the base source but not what
                // dimension the others vary by, since the uploader chose those
                // names. A resolution or HDR guess here would imply a
                // convention that may not apply — an "Extended Version" beside
                // an identically-encoded original. "Original" is never wrong.
                label = Self.editionLabel(for: source, canonicalName: canonicalName)
                    ?? String(localized: "Original")
            } else {
                label = Self.versionLabel(for: source, fallbackIndex: index)
            }
            // Two versions can land on the same coarse label (two 1080p SDR
            // encodes), which would offer indistinguishable menu entries.
            if !seenLabels.insert(label).inserted {
                label += " (\(index + 1))"
            }
            return MediaVersion(id: source.id ?? String(index), label: label)
        }
    }

    /// Badges for `InfoMetadataRow`: resolution class, dynamic range, audio
    /// format and accessibility tracks. Separate from `technicalDetails`, since
    /// a "4K"/"HD" badge needs a coarser bucket than that view's exact
    /// dimensions.
    ///
    /// Each audio family collapses to one best badge rather than listing every
    /// track: Atmos > DD+ > DD, and DTS-HD > DTS. Dolby TrueHD is the exception
    /// and shows alongside the winning Dolby Digital badge, since a TrueHD
    /// track often carries an Atmos layer — Atmos + TrueHD + DTS-HD is valid,
    /// while Atmos + DD+ is not.
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

        // Forced subtitles (foreign dialogue only) aren't closed captions;
        // unspecified counts.
        if subtitleStreams.contains(where: { $0.isForced != true }) {
            badges.append("CC")
        }

        if audioStreams.contains(where: Self.isAccessibilityAudioTrack) {
            badges.append("AD")
        }

        return badges
    }

    /// `mediaVersions`' fallback label when `editionLabel` recovers no edition
    /// name: a coarse resolution and dynamic-range pair like "4K HDR10", using
    /// `metadataBadges`' buckets rather than `technicalDetails`' exact
    /// dimensions, since a picker entry must read at a glance. Falls back to the
    /// server's raw `MediaSourceInfo.name`, then to "Version N".
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
    /// extends, per Jellyfin's multi-version naming convention: alternate cuts
    /// sit beside the primary file as `<primary file name> - <edition name>.ext`.
    /// `MediaSourceInfo.name` is the filename-derived stem, so the canonical
    /// source is whichever name is a literal prefix of every other's. `nil` when
    /// that doesn't hold, leaving callers to fall back to `versionLabel`.
    ///
    /// Not "split on ` - ` and take the last piece": filenames carry unrelated
    /// dashes of their own (`[Bluray-2160p]`, `x265]-GROUP`), so only a prefix
    /// comparison isolates the edition suffix reliably.
    private static func canonicalSourceName(_ sources: [MediaSourceInfo]) -> String? {
        let names = sources.map { $0.name ?? "" }
        guard sources.count > 1, names.allSatisfy({ !$0.isEmpty }) else { return nil }
        return names.first { candidate in
            names.allSatisfy { $0 == candidate || $0.hasPrefix(candidate + " - ") }
        }
    }

    /// The edition name encoded relative to `canonicalName` ("Extended
    /// Version", "Black and White"), verbatim as the uploader wrote it. `nil`
    /// for the canonical version, and when this name doesn't extend it.
    private static func editionLabel(for source: MediaSourceInfo, canonicalName: String?) -> String? {
        guard let canonicalName, let name = source.name, name != canonicalName else { return nil }
        let prefix = canonicalName + " - "
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = String(name.dropFirst(prefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    /// Coarse "Dolby Vision"/"HDR10"/"HDR10+"/"HDR" buckets from Jellyfin's raw
    /// `VideoRangeType`/`VideoRange`, shared by `metadataBadges` and
    /// `versionLabel`. `nil` for SDR, which needs no badge.
    private static func dynamicRangeBadge(_ dynamicRangeType: String) -> String? {
        if dynamicRangeType.hasPrefix("DOVI") { return "Dolby Vision" }
        switch dynamicRangeType {
        case "HDR10": return "HDR10"
        case "HDR10Plus": return "HDR10+"
        case "HLG": return "HDR"
        default: return nil
        }
    }

    /// A `mediaSources` entry by id, falling back to the first when `versionID`
    /// is nil or unmatched. A function rather than an inline `flatMap`/`??`,
    /// which the type-checker couldn't resolve in reasonable time.
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

    /// Every DTS variant reports `codec == "dts"`; only `profile` distinguishes
    /// "DTS-HD MA" and "DTS-HD HRA" from plain or core-only DTS.
    private static func isDTSHD(_ stream: MediaStream) -> Bool {
        guard (stream.codec ?? "").caseInsensitiveCompare("dts") == .orderedSame else { return false }
        return (stream.profile ?? "").localizedCaseInsensitiveContains("dts-hd")
    }

    /// SDH is a subtitle convention, but an audio track can be tagged the same
    /// way for a described or hearing-impaired mix. `isHearingImpaired` is the
    /// closest signal Jellyfin exposes; matching the title catches tracks the
    /// server hasn't flagged.
    private static func isAccessibilityAudioTrack(_ stream: MediaStream) -> Bool {
        if stream.isHearingImpaired == true { return true }
        let haystack = [stream.title, stream.displayTitle].compactMap { $0 }.joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains("sdh")
            || haystack.localizedCaseInsensitiveContains("audio description")
            || haystack.localizedCaseInsensitiveContains("hard of hearing")
    }

    /// Named position markers for `ChapterRailView` and the player's chapter
    /// scrubber and picker. Populated only under `Fields=Chapters`; `[]` for
    /// lighter fetches.
    ///
    /// A single-entry array counts as no chapters: Jellyfin emits one dummy
    /// chapter at 00:00 for unchaptered content, and a picker offering only the
    /// position playback already starts at is worse than none. Applied here so
    /// every consumer doesn't re-apply the same `count > 1` rule.
    var chapters: [Chapter] {
        let dtos = dto.chapters ?? []
        guard dtos.count > 1 else { return [] }
        return dtos.enumerated().map { index, chapter in
            Chapter(dto: chapter, index: index, itemID: dto.id, images: images)
        }
    }

    /// Cast and crew in server order, which puts billed actors before crew.
    /// Populated only under `Fields=People`.
    ///
    /// `id` combines the person's id with their position, because one person can
    /// hold several credits — an actor who also directed, or with two roles —
    /// sharing a Guid across entries. `CastCrewGridView`'s `ForEach` needs one
    /// identifier per credit; duplicates there produce intermittent gaps and
    /// repeated cells while scrolling.
    var cast: [CastMember] {
        (dto.people ?? []).enumerated().map { index, person in
            CastMember(
                id: "\(person.id)-\(index)",
                name: person.name,
                // Actors get a character name in `role`; crew usually don't, so
                // fall back to their job title.
                role: (person.role?.isEmpty ?? true) ? person.type : person.role,
                imageURL: person.primaryImageTag.flatMap {
                    images.url(itemID: person.id, imageType: "Primary", tag: $0, maxWidth: 200)
                }
            )
        }
    }

    // MARK: - Technical details formatting

    /// Non-`private`: `DownloadedTechnicalDetailsView` reuses this
    /// "dimensions (common name)" formatting, so the two Details tabs can't
    /// show the same resolution two different ways.
    static func resolutionLabel(width: Int, height: Int) -> String {
        let dimensions = "\(width)\u{00D7}\(height)"
        return resolutionCommonName(width: width).map { "\(dimensions) (\($0))" } ?? dimensions
    }

    /// Classifies by width: a letterboxed 2.39:1 source keeps its full width but
    /// has reduced height, so bucketing by height would demote a true 4K
    /// release. Shared by `resolutionLabel` and `metadataBadges`.
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

    /// `VideoRangeType` is the more specific field where present, distinguishing
    /// Dolby Vision profiles that carry an HDR10 or HLG fallback layer. The
    /// `default` case handles the simpler `VideoRange` values too.
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

    /// Prefers the server's `displayTitle`, already formatted as
    /// "English (AAC 5.1)", and assembles one from the available fields when a
    /// stream has none.
    private static func trackLabel(for stream: MediaStream) -> String {
        if let displayTitle = stream.displayTitle, !displayTitle.isEmpty { return displayTitle }
        let parts = [stream.language, stream.codec?.uppercased()].compactMap { $0 }
        return parts.isEmpty ? String(localized: "Track \(stream.index + 1)") : parts.joined(separator: " \u{00B7} ")
    }

    /// "23.976 fps", "60 fps" — up to three decimals, trailing zeros and a bare
    /// decimal point trimmed.
    private static func frameRateLabel(_ fps: Double) -> String {
        var formatted = String(format: "%.3f", fps)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return "\(formatted) fps"
    }

    private static func bitrateLabel(_ bitsPerSecond: Int) -> String {
        String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
    }

    /// `bitrateLabel`'s VoiceOver counterpart; "Mbps" is otherwise read letter
    /// by letter.
    private static func bitrateAccessibilityLabel(_ bitsPerSecond: Int) -> String {
        let mbps = String(format: "%.1f", Double(bitsPerSecond) / 1_000_000)
        return String(localized: "\(mbps) megabits per second")
    }

    private static func fileSizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// `fileSizeLabel`'s VoiceOver counterpart; "2.44 GB" is otherwise read as
    /// "two dot forty-four G B". Spells out the unit in `fileSizeLabel`'s own
    /// output rather than reimplementing its unit selection and rounding, so
    /// the two can't drift. An unrecognized unit passes through unchanged — a
    /// wrong readout would be worse than an unexpanded one.
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

    /// The 16:9 "Thumb" image: a still frame, which episodes almost always have
    /// and series sometimes do.
    ///
    /// `nil` when absent rather than a URL that 404s. `imageURL(type:)` builds a
    /// URL whether or not `dto.imageTags` has an entry, which suits
    /// `primaryImageURL` but would break `LandscapeMediaCard`'s
    /// `thumbImageURL ?? primaryImageURL` — the `??` would never reach the
    /// poster. Checking the tag directly is what makes that fallback real.
    var thumbImageURL: URL? {
        guard let tag = dto.imageTags?["Thumb"] else { return nil }
        return images.url(itemID: id, imageType: "Thumb", tag: tag, maxWidth: 500)
    }

    /// Whether this item's rail tile uses `LandscapeMediaCard` rather than
    /// `PosterCard`: series and episodes read better as a still frame, and
    /// episodes often have no compelling poster art. Consulted only by
    /// `MediaRailView`, but kept here as a display decision about the item, like
    /// `railTitle`/`railSubtitle`.
    var usesLandscapeRailTile: Bool {
        switch dto.type {
        case .series, .episode: return true
        default: return false
        }
    }

    /// Own logo, else the nearest ancestor's — an episode falls back to its
    /// Season, then its Series. `nil` rather than a 404ing URL when nothing in
    /// the hierarchy has one, so callers can fall back to title text.
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

    /// A copy carrying a just-closed session's final position, so a known-correct
    /// value shows immediately instead of waiting on a server round-trip (see
    /// `AssetDetailViewModel.applyOptimisticPlaybackPosition(_:)`). Overwrites
    /// only `userData`'s position fields, leaving `played` alone. A no-op for a
    /// non-positive duration, which yields no meaningful fraction.
    func withOptimisticPlaybackPosition(seconds: TimeInterval, duration: TimeInterval) -> MediaItem {
        guard duration > 0 else { return self }
        var newDto = dto
        var userData = newDto.userData ?? UserItemDataDto()
        userData.playbackPositionTicks = Int64(seconds * 10_000_000)
        userData.playedPercentage = min(100, max(0, (seconds / duration) * 100))
        newDto.userData = userData
        return MediaItem(dto: newDto, images: images)
    }

    /// `withOptimisticPlaybackPosition`'s sibling for `isFavorite`/`isPlayed`.
    /// A favorite or watched write can return success and still take minutes to
    /// commit server-side, well past this app's confirmation poll, so without
    /// applying the known value at once the toolbar button looks unresponsive.
    ///
    /// Each parameter defaults to `nil`, meaning leave that field as-is, so a
    /// caller changing one needn't know the other's value.
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
    /// Structural, over every field of `BaseItemDto`. Do not narrow this to an
    /// id comparison.
    ///
    /// SwiftUI prefers a stored property's own `==` over its internal comparison
    /// when deciding whether a view changed. `MediaItem` is the stored property
    /// of essentially every view here, and `[MediaItem]` is what
    /// `ForEach(rail.items)` diffs on, so an id-only `==` promises that nothing
    /// under a stable id is worth repainting — false for `userData` after
    /// playback, and for `mediaSources`/`people` when `AssetDetailViewModel`
    /// swaps its preloaded item for the full fetch. Both froze views on their
    /// first-rendered values.
    ///
    /// `images` is excluded: a session-config snapshot, identical for every item
    /// and never a reason to repaint.
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.dto == rhs.dto }

    /// Id-only although `==` is structural — the legal direction for the
    /// `Hashable` contract, and what keeps id-keyed lookups treating one server
    /// item as one entry rather than one per revision of its fields.
    func hash(into hasher: inout Hasher) { hasher.combine(dto.id) }
}
