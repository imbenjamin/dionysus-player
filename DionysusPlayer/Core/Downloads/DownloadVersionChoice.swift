import Foundation

/// Which version a single-title download fetches (#289), apart from
/// `DownloadButton` so the rule is tested without a view.
///
/// Not `MediaVersionChoice.decide`: a download isn't a resume, so the
/// remembered *playback* pick never answers for it. With two or more
/// versions it asks every time, marking that pick "(Last Played)" (D8),
/// since what someone wants on a plane (the smaller 1080p) is often not what
/// they play at home. The long-press sheet's Version picker is the other way
/// to answer (D9), and nothing asks after it when it offered one.
enum DownloadVersionChoice {
    enum Decision: Equatable {
        /// Download this source. `versionLabel` is what the download records
        /// and its Details shows; `nil` for a title with only one version.
        case download(mediaSourceID: String?, versionLabel: String?)
        /// Ask which, with `versionChoiceDialog`.
        case ask(versions: [MediaVersion], lastPlayedID: String?)
        /// `/PlaybackInfo` listed nothing to download.
        case noSource
    }

    /// `sources` is `/PlaybackInfo`'s answer for the item, every source.
    /// `preselectedSourceID` is the sheet's Version picker, `nil` when the
    /// sheet showed none.
    ///
    /// Only a pick that still names a listed version answers the question.
    /// A sheet with no picker (its own fetch failed, or the item listed one
    /// source then) said nothing about versions, and a pick gone by the time
    /// of this fetch names none: either way this asks after the sheet rather
    /// than silently downloading the first, which might be the 4K file
    /// someone meant to leave at home.
    static func decide(
        sources: [MediaSourceInfo],
        preselectedSourceID: String?,
        rememberedSourceID: String?
    ) -> Decision {
        guard let first = sources.first else { return .noSource }
        let versions = MediaVersion.versions(of: sources)
        guard versions.count > 1 else { return .download(mediaSourceID: first.id, versionLabel: nil) }
        if let preselectedSourceID, versions.contains(where: { $0.id == preselectedSourceID }) {
            return answer(preselectedSourceID, sources: sources)
        }
        let remembered = rememberedSourceID.flatMap { id in versions.contains { $0.id == id } ? id : nil }
        return .ask(versions: versions, lastPlayedID: remembered)
    }

    /// The question's answer, labelled as the question listed it.
    static func answer(_ mediaSourceID: String, sources: [MediaSourceInfo]) -> Decision {
        let label = MediaVersion.versions(of: sources).first { $0.id == mediaSourceID }?.label
        return .download(mediaSourceID: mediaSourceID, versionLabel: label)
    }

    /// The sheet's Version picker starts on the remembered playback pick,
    /// else the server's default (the first). `nil` with nothing to pick.
    static func initialSheetSelection(versions: [MediaVersion], rememberedSourceID: String?) -> String? {
        guard versions.count > 1 else { return nil }
        if let rememberedSourceID, versions.contains(where: { $0.id == rememberedSourceID }) { return rememberedSourceID }
        return versions.first?.id
    }

    /// The source `mediaSourceID` names, else the first: what the sheet's
    /// size estimate reads, so it follows the selected version.
    static func source(for mediaSourceID: String?, in sources: [MediaSourceInfo]) -> MediaSourceInfo? {
        mediaSourceID.flatMap { id in sources.first { $0.id == id } } ?? sources.first
    }
}
