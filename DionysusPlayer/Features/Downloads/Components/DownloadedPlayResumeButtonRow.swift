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
    /// `nil` when there's no live session at all — the offline Downloads
    /// pages this view sits on are deliberately usable with no session
    /// (see `AppRouteDestinationView`'s own doc comment), but retrying a
    /// failed download needs a real `JellyfinAPIClient` to re-negotiate
    /// against (see `DownloadManager.retry(itemID:client:)`), so the Retry
    /// button below only appears when one's actually available.
    var client: JellyfinAPIClient?
    var onPlay: () -> Void
    var onRestart: () -> Void

    @State private var isRetrying = false
    @State private var isShowingRetryError = false
    @State private var retryErrorMessage = ""

    private var isPartWatched: Bool {
        !item.isPlayed && item.resumePositionTicks > 0
    }

    /// "Play"/"Resume"/"Play Again", with an "SXX:EYY" suffix whenever
    /// `item.episodeLabel` is set — same idea as `PlayResumeButtonRow
    /// .buttonTitle`'s own suffix, and what carries the episode number for
    /// this page instead of a separate on-screen label (see
    /// `DownloadedAssetDetailView`'s own doc comment on why the episode/
    /// series title doesn't appear elsewhere as plain text).
    private var buttonTitle: String {
        guard let label = item.episodeLabel else {
            if item.isPlayed { return String(localized: "Play Again") }
            return isPartWatched ? String(localized: "Resume") : String(localized: "Play")
        }
        if item.isPlayed { return String(localized: "Play Again \(label)") }
        return isPartWatched ? String(localized: "Resume \(label)") : String(localized: "Play \(label)")
    }

    /// See `PlayResumeButtonRow.accessibilityLabelText`'s identical
    /// reasoning — "Resume from 11 minutes" instead of repeating the
    /// episode number the hero above this row already announced.
    private var accessibilityLabelText: String {
        guard isPartWatched, let resumeText = item.resumePositionAccessibilityText else { return buttonTitle }
        return String(localized: "Resume from \(resumeText)")
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
                .accessibilityLabel(accessibilityLabelText)
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
                    // See `PlayResumeButtonRow`'s identical fix — without
                    // this, VoiceOver falls back to the SF Symbol's own name.
                    .accessibilityLabel(String(localized: "Restart"))
                }
            }
        } else {
            downloadStatusRow
        }
    }

    /// Stands in for the Play/Resume row while the download isn't actually
    /// playable yet — same content `DownloadedAssetDetailView` used to
    /// render directly, moved here so this one view owns "what goes where
    /// Play normally is" for every state. `.failed` breaks out into its
    /// own `failedRow` below (a Retry button needs a second line, not just
    /// another cell in this shared single-line `HStack`).
    @ViewBuilder
    private var downloadStatusRow: some View {
        if item.status == .failed {
            failedRow
        } else {
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
                case .paused:
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text("Download Paused")
                case .completed, .failed:
                    EmptyView()
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Retries right where the failure is already shown, reusing the exact
    /// resolution/quality/audio choice the original attempt used — see
    /// `DownloadManager.retry(itemID:client:)`'s own doc comment.
    private var failedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(item.errorMessage ?? String(localized: "Download failed."))
            }
            .foregroundStyle(.secondary)

            // Hidden rather than shown-disabled when there's no live
            // session — this page is reachable fully offline (see
            // `client`'s own doc comment), and a missing button reads as
            // "nothing to do right now" clearly enough on its own.
            if let client {
                Button(action: { retry(client: client) }) {
                    Label {
                        Text(isRetrying ? "Retrying…" : "Retry Download")
                    } icon: {
                        if isRetrying {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.dionysusPrimary)
                .disabled(isRetrying)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Couldn't Retry Download", isPresented: $isShowingRetryError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(retryErrorMessage)
        }
    }

    private func retry(client: JellyfinAPIClient) {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            defer { isRetrying = false }
            do {
                try await downloadManager.retry(itemID: item.itemID, client: client)
            } catch {
                retryErrorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't retry this download.")
                isShowingRetryError = true
            }
        }
    }
}
