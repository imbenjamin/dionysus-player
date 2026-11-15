import Foundation

/// What starting playback does about an item's versions: play one straight
/// away, or ask which. Pure, so the rule is tested once and both apps (and the
/// next-episode hand-off) apply the same one.
enum MediaVersionChoice: Equatable {
    /// Play now. `nil` leaves the choice to the server (its default version),
    /// which is what an item with nothing to choose between has always done.
    case play(mediaSourceID: String?)
    /// Ask first. `lastPlayedID` marks the remembered pick in the list when it
    /// is still among `versions`, and is `nil` when there is nothing to mark.
    case ask(versions: [MediaVersion], lastPlayedID: String?)

    /// `isResume` is whether the title has a resume point, whichever button
    /// started it: Resume and Restart alike (Benjamin, 2026-11-13).
    ///
    /// Without a resume point, a start asks whenever there are two or more
    /// versions, since a remembered pick is a suggestion, not an answer: the
    /// user may want the other cut this time. With one, the remembered pick
    /// plays, because the position belongs to that file; with no pick still
    /// among the versions (never chosen, or the file was removed) it asks,
    /// with no mark.
    ///
    /// A remembered id that is no longer listed is treated as no pick at all,
    /// so a stale id is never sent to the server or marked in the list.
    static func decide(
        versions: [MediaVersion],
        isResume: Bool,
        preferredSourceID: String?
    ) -> MediaVersionChoice {
        guard versions.count > 1 else { return .play(mediaSourceID: nil) }
        let remembered = preferredSourceID.flatMap { id in
            versions.contains { $0.id == id } ? id : nil
        }
        if isResume, let remembered { return .play(mediaSourceID: remembered) }
        return .ask(versions: versions, lastPlayedID: remembered)
    }

    /// The next episode of a session already under way: it shouldn't interrupt
    /// with a question when the answer is evident. The remembered pick wins,
    /// then the version labelled as the one just watched ("1080p" stays
    /// "1080p" across episodes, whose ids all differ), else ask with no mark.
    static func continuation(
        versions: [MediaVersion],
        preferredSourceID: String?,
        previousLabel: String?
    ) -> MediaVersionChoice {
        guard versions.count > 1 else { return .play(mediaSourceID: nil) }
        if let preferredSourceID, versions.contains(where: { $0.id == preferredSourceID }) {
            return .play(mediaSourceID: preferredSourceID)
        }
        if let previousLabel, let match = versions.first(where: { $0.label == previousLabel }) {
            return .play(mediaSourceID: match.id)
        }
        return .ask(versions: versions, lastPlayedID: nil)
    }
}

/// A version question waiting for its answer: what each app's question (iOS's
/// dialog, the Apple TV's page) lists, built from `MediaVersionChoice.ask`.
/// Here rather than beside either question because the Apple TV compiles
/// `Core/` but not the iOS components. `id` is fresh per question, so asking
/// the same thing twice in a row still presents twice.
struct PendingVersionChoice: Identifiable {
    let id = UUID()
    let versions: [MediaVersion]
    /// Marked "(Last Played)" in the list; `nil` marks nothing.
    let lastPlayedID: String?
}
