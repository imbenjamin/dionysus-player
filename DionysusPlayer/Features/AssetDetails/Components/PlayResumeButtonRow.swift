import SwiftUI

/// The Play/Resume + Restart button row on the movie and show detail pages.
///
/// - Not-yet-watched: single "Play" button.
/// - Part-watched: "Resume" button (shortened to make room), a small
///   icon-only "Restart" button next to it, and a thin `dionysusProgress`
///   bar along the bottom of the primary button showing playback progress.
///
/// Version handling (see `MediaItem.mediaVersions`): "Resume" always
/// continues in place with whatever version resume tracking already applies
/// to — Jellyfin's own resume position is per item, not per version, so
/// there's nothing to choose there, and interrupting a returning viewer with
/// a prompt would be actively unhelpful. "Play" (first watch) and "Restart"
/// (starting over) are both a *fresh* start, though, so either one prompts
/// for a version first whenever `item` actually has more than one —
/// `onPlay`/`onRestart` receive that choice as their `MediaVersion.id`
/// argument (`nil` when there was nothing to choose between, i.e.
/// `item.mediaVersions` is empty). Callers are expected to remember that
/// choice (`AssetDetailViewModel.setPreferredMediaSourceID`) so a later
/// Resume can look it up instead of guessing.
struct PlayResumeButtonRow: View {
    let item: MediaItem
    /// Fresh start (unwatched item's "Play") — the chosen version's
    /// `MediaVersion.id`, or `nil` when there was nothing to choose between.
    var onPlay: (String?) -> Void
    /// Continue a part-watched item from its saved position — no version
    /// prompt; see this type's doc comment for why.
    var onResume: () -> Void
    /// Restart a part-watched item from 0 — same version-choice behavior as
    /// `onPlay`.
    var onRestart: (String?) -> Void

    /// Which fresh-start action the version-choice `confirmationDialog` is
    /// currently resolving. Only meaningful while `isShowingVersionPrompt`
    /// is true (see `beginFreshStart(_:)`) — its value the rest of the time
    /// is stale/irrelevant, same as any other `@State` that's only "live"
    /// while its associated presentation is up.
    @State private var pendingFreshStart: FreshStartAction = .play
    /// Deliberately a plain `@State Bool` — driven by `pendingFreshStart` —
    /// rather than a computed `Binding` derived from `pendingFreshStart`
    /// being non-`nil`. That reads as equivalent, but a computed `Binding`
    /// standing in for `confirmationDialog`'s `isPresented` turned out to be
    /// unreliable across repeated presentations in the same view's
    /// lifetime: reproduced live in the Simulator, where the third/fourth
    /// "Play" tap in one continuous session silently skipped the prompt and
    /// fell straight through to the server's default version, with no
    /// change to `item.mediaVersions` explaining it. A real stored `@State`
    /// projected directly (`$isShowingVersionPrompt`) is the pattern Apple's
    /// own documentation uses and didn't reproduce the issue across many
    /// repeated cycles in the same manual test.
    @State private var isShowingVersionPrompt = false

    private enum FreshStartAction { case play, restart }

    /// Corner radius applied to both the button's border shape AND the outer
    /// clip. Matching the two is what makes the progress bar tuck in behind
    /// the button's curved edges instead of poking past them.
    private let cornerRadius: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { item.isPartWatched ? onResume() : beginFreshStart(.play) }) {
                Label(item.isPartWatched ? "Resume" : "Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
            .tint(.dionysusPrimary)
            .controlSize(.large)
            .overlay(alignment: .bottom) {
                if item.isPartWatched, let fraction = item.playedFraction {
                    GeometryReader { geo in
                        Color.dionysusProgress
                            .frame(width: geo.size.width * fraction)
                    }
                    .frame(height: 3)
                    .allowsHitTesting(false)
                }
            }
            // Clips button + overlay together to the same rounded rect the
            // button's border shape uses, so the progress bar's rectangular
            // corners get masked by the button's curve rather than poking out.
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            if item.isPartWatched {
                Button(action: { beginFreshStart(.restart) }) {
                    Image(systemName: "arrow.counterclockwise")
                        // Manual foreground: `.borderedProminent` picks white
                        // by default, but on a 70%-lightened tint white has
                        // poor contrast, so use the primary shade instead.
                        .foregroundStyle(Color.dionysusPrimary)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
                .tint(.dionysusPrimaryLight)
                .controlSize(.large)
            }
        }
        .confirmationDialog(
            "Choose a Version", isPresented: $isShowingVersionPrompt, titleVisibility: .visible
        ) {
            ForEach(item.mediaVersions) { version in
                Button(version.label) { resolve(pendingFreshStart, mediaSourceID: version.id) }
            }
        }
    }

    /// Only actually prompts when there's a real choice to make
    /// (`mediaVersions.count > 1`, per its own doc comment) — otherwise
    /// resolves immediately with `nil`, identical to the pre-version-picker
    /// behavior.
    private func beginFreshStart(_ action: FreshStartAction) {
        guard item.mediaVersions.count > 1 else {
            resolve(action, mediaSourceID: nil)
            return
        }
        pendingFreshStart = action
        isShowingVersionPrompt = true
    }

    private func resolve(_ action: FreshStartAction, mediaSourceID: String?) {
        switch action {
        case .play: onPlay(mediaSourceID)
        case .restart: onRestart(mediaSourceID)
        }
        isShowingVersionPrompt = false
    }
}
