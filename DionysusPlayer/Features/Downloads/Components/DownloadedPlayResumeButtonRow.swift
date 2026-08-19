import SwiftUI

/// The offline counterpart to `PlayResumeButtonRow` — same visual shape
/// (bordered-prominent Play/Resume button with a progress-bar overlay, plus
/// a small icon-only Restart button once part-watched), simplified since a
/// download only ever has the one version that was actually fetched (no
/// version-choice prompt to make).
///
/// Before the file is actually playable (`item.status != .completed` — the
/// file may not exist yet at all, or be only partially written), this
/// stands in with the same download-progress row `DownloadButton`/
/// `DownloadsView` already use, rather than a Play button that would fail
/// or play garbage.
struct DownloadedPlayResumeButtonRow: View {
    let item: DownloadedItem
    let downloadManager: DownloadManager
    var onPlay: () -> Void
    var onRestart: () -> Void

    private var isPartWatched: Bool {
        !item.isPlayed && item.resumePositionTicks > 0
    }

    /// "Play"/"Resume"/"Play Again", with an "SXX:EYY" suffix whenever
    /// `item.episodeLabel` is set — same idea as `PlayResumeButtonRow
    /// .buttonTitle`'s own suffix, and what carries the episode number for
    /// this page instead of a separate on-screen label: see this type's
    /// own doc comment on why the episode/series title no longer appears
    /// as plain text elsewhere on `DownloadedAssetDetailView` — confirmed
    /// live (2026-08-19) against a real Show page that this is exactly
    /// where "S1:E4" belongs, not a standalone line of its own.
    private var buttonTitle: String {
        guard let label = item.episodeLabel else {
            if item.isPlayed { return String(localized: "Play Again") }
            return isPartWatched ? String(localized: "Resume") : String(localized: "Play")
        }
        if item.isPlayed { return String(localized: "Play Again \(label)") }
        return isPartWatched ? String(localized: "Resume \(label)") : String(localized: "Play \(label)")
    }

    /// Same corner radius on both the button's border shape and the outer
    /// clip as `PlayResumeButtonRow` — what tucks the progress bar in
    /// behind the button's curved edges instead of poking past them.
    private let cornerRadius: CGFloat = 12

    var body: some View {
        if item.status == .completed {
            HStack(spacing: 8) {
                Button(action: onPlay) {
                    Label {
                        Text(buttonTitle)
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
                .tint(.dionysusPrimary)
                .controlSize(.large)
                .overlay(alignment: .bottom) {
                    if isPartWatched {
                        GeometryReader { geo in
                            Color.dionysusProgress
                                .frame(width: geo.size.width * item.playedPercentage / 100)
                        }
                        .frame(height: 3)
                        .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                if isPartWatched {
                    Button(action: onRestart) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(Color.dionysusPrimary)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
                    .tint(.dionysusPrimaryLight)
                    .controlSize(.large)
                }
            }
        } else {
            downloadStatusRow
        }
    }

    /// Stands in for the Play/Resume row while the download isn't actually
    /// playable yet — same content `DownloadedAssetDetailView` used to
    /// render directly, moved here so this one view owns "what goes where
    /// Play normally is" for every state.
    @ViewBuilder
    private var downloadStatusRow: some View {
        HStack(spacing: 12) {
            switch item.status {
            case .downloading:
                if let progress = downloadManager.activeDownloads[item.itemID] {
                    DownloadProgressRing(progress: progress)
                        .frame(width: 32, height: 32)
                    Text(progress.statusText)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Preparing download…")
                }
            case .queued:
                // Waiting for a concurrency slot (`DownloadPreferencesStore
                // .maxConcurrentDownloads`) — distinct from `.downloading`'s
                // own brief "no bytes yet" moment above, worth its own
                // label so a download that's been waiting behind others
                // doesn't read as stuck.
                ProgressView().controlSize(.small)
                Text("Queued…")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(item.errorMessage ?? String(localized: "Download failed."))
            case .paused:
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("Download Paused")
            case .completed:
                EmptyView()
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
