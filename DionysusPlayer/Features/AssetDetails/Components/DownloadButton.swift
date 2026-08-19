import SwiftUI

/// Starts an offline download of `item` — placed near `PlayResumeButtonRow`
/// on the detail page. Fetches `playbackInfo` to see the item's real
/// audio/subtitle tracks (not visible to a Movie/Episode-content page
/// otherwise), prompts for an audio track when there's more than one (the
/// same `confirmationDialog` idiom `PlayResumeButtonRow`'s version picker
/// already uses), warns before proceeding if that would leave the download
/// without its default/forced subtitle track (image-based tracks can't be
/// brought offline — see `JellyfinAPIClient.isImageBasedSubtitleCodec`),
/// then hands off to `DownloadManager.enqueue`. Quality/resolution come
/// from `DownloadPreferencesStore` (`ProfileView`'s Downloads settings) —
/// not chosen per-download here.
struct DownloadButton: View {
    let item: MediaItem
    let client: JellyfinAPIClient
    let userID: String
    let downloadManager: DownloadManager

    private let preferences = DownloadPreferencesStore()

    @State private var isResolving = false
    @State private var pendingResolution: PendingDownload?
    @State private var isShowingAudioPrompt = false
    @State private var isShowingSubtitleWarning = false
    @State private var isShowingError = false
    @State private var errorMessage = ""

    /// What's been resolved from `playbackInfo` so far, waiting on the
    /// audio-track prompt (if any) before `beginDownload(audioTrack:)` can
    /// actually enqueue.
    private struct PendingDownload {
        var mediaSource: MediaSourceInfo
        var audioTracks: [MediaStream]
        var subtitleTracks: [MediaStream]
    }

    private var downloadedRow: DownloadedItem? { downloadManager.store.item(itemID: item.id) }

    /// Live byte progress while a download for this item is actually in
    /// flight — `nil` before/after, including while `isResolving`/
    /// `isPreparing` (both precede an actual download and have no byte
    /// count of their own to show).
    private var progress: DownloadProgress? {
        guard let row = downloadedRow, row.status == .downloading || row.status == .queued else { return nil }
        return downloadManager.activeDownloads[item.id]
    }
    /// The `DownloadedItem` row exists and is queued/downloading, but the
    /// background video task hasn't started reporting real byte progress
    /// yet — `DownloadManager.enqueue` spends real time up front (fetching
    /// the metadata/artwork snapshot, subtitle sidecars) before the video
    /// task itself starts, so this window is routinely a second or more,
    /// not instantaneous. Without accounting for it separately from
    /// `isResolving` (the *earlier* `playbackInfo`-fetch/prompt phase),
    /// the button fell through to its plain idle icon here — indistinguishable
    /// from "not downloading at all" — confirmed live (2026-08-19) as
    /// reading like the tap hadn't registered.
    private var isPreparing: Bool {
        guard let row = downloadedRow, row.status == .downloading || row.status == .queued else { return false }
        return downloadManager.activeDownloads[item.id] == nil
    }
    private var isDownloading: Bool {
        downloadManager.activeDownloads[item.id] != nil
    }
    private var isDownloaded: Bool {
        downloadedRow?.status == .completed
    }
    /// Everything that should block a second tap — resolving, preparing,
    /// or actively downloading. `isResolving || isDownloading` alone
    /// (the original condition) left the button tappable again during the
    /// `isPreparing` window above, which could fire a second, redundant
    /// `enqueue` for the same item.
    private var isBusy: Bool { isResolving || isPreparing || isDownloading }

    /// Matches `PlayResumeButtonRow`'s "Restart" button exactly — same
    /// bordered-prominent/rounded-rect/large-control-size/light-tint shape,
    /// and deliberately no explicit `.frame` either (same as Restart's own
    /// bare `Image`) so the system sizes this the same modest amount
    /// around its glyph rather than a fixed, oversized square — so this
    /// reads as a peer transport action next to Play/Resume/Restart, not
    /// an oversized afterthought tacked on beside it.
    private let cornerRadius: CGFloat = 12
    /// Only the progress ring needs an explicit size (unlike a system SF
    /// Symbol, it has no intrinsic one) — picked to land at roughly the
    /// same visual weight as Restart's own `Image(systemName:)` glyph at
    /// `.large` control size.
    private let ringSize: CGFloat = 20

    var body: some View {
        Group {
            if isDownloaded {
                // Already downloaded — a second tap should open the
                // download's own page (to play it offline, check its
                // size, or delete it), not silently re-download the same
                // item from scratch.
                NavigationLink(value: AppRoute.downloadedAsset(itemID: item.id)) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.dionysusPrimary)
                        .frame(width: ringSize, height: ringSize)
                }
            } else {
                Button(action: startResolving) {
                    // Every branch shares the same explicit frame — a
                    // plain `Image(systemName:)`, a bare `ProgressView()`,
                    // and `DownloadProgressRing` each report a different
                    // natural size to their parent when left unconstrained
                    // (`ProgressView()` in particular renders noticeably
                    // larger than the SF Symbol glyph at this control
                    // size), so without this the button's own footprint
                    // visibly popped to a different size for a frame or
                    // two on every state change — confirmed live
                    // (2026-08-19) — before settling back once the new
                    // content re-laid-out. One fixed frame around whatever
                    // the current branch renders keeps the button itself a
                    // constant size throughout.
                    Group {
                        if let progress {
                            DownloadProgressRing(progress: progress)
                        } else if isResolving || isPreparing {
                            // A plain spinner, not the progress ring —
                            // there's no determined byte progress yet to
                            // show as one (see `isPreparing`'s own doc
                            // comment), and an indeterminate ring at 0%
                            // reads as "stuck", not "starting".
                            ProgressView()
                                .tint(Color.dionysusPrimary)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(Color.dionysusPrimary)
                        }
                    }
                    .frame(width: ringSize, height: ringSize)
                }
                .disabled(isBusy)
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
        .tint(.dionysusPrimaryLight)
        .controlSize(.large)
        .confirmationDialog(
            "Choose an Audio Track", isPresented: $isShowingAudioPrompt, titleVisibility: .visible
        ) {
            if let pendingResolution {
                ForEach(pendingResolution.audioTracks, id: \.index) { track in
                    Button(track.displayTitle ?? String(localized: "Track \(track.index + 1)")) {
                        resolveAudioTrack(track)
                    }
                }
            }
        }
        .alert("Subtitle Track Unavailable Offline", isPresented: $isShowingSubtitleWarning) {
            Button("Download Anyway") {
                if let pendingResolution {
                    Task { await enqueue(mediaSource: pendingResolution.mediaSource, audioTrack: pendingResolution.audioTracks.first, subtitleTracks: pendingResolution.subtitleTracks) }
                }
            }
            Button("Cancel", role: .cancel) { pendingResolution = nil }
        } message: {
            Text("This title's default subtitle track can't be included in offline downloads. The download will have no subtitles unless you choose one manually later.")
        }
        .alert("Couldn't Start Download", isPresented: $isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func startResolving() {
        guard !isResolving, !isDownloading else { return }
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                let info = try await client.playbackInfo(itemID: item.id, userID: userID)
                guard let mediaSource = info.mediaSources?.first else {
                    presentError(DownloadError.missingMediaSource.errorDescription ?? "")
                    return
                }
                let streams = mediaSource.mediaStreams ?? []
                let audioTracks = streams.filter { $0.type == "Audio" }
                let subtitleTracks = streams.filter { $0.type == "Subtitle" }
                let resolution = PendingDownload(mediaSource: mediaSource, audioTracks: audioTracks, subtitleTracks: subtitleTracks)
                pendingResolution = resolution

                if audioTracks.count > 1 {
                    isShowingAudioPrompt = true
                } else {
                    resolveAudioTrack(audioTracks.first)
                }
            } catch {
                presentError((error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't fetch playback info for this item."))
            }
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        isShowingError = true
    }

    private func resolveAudioTrack(_ audioTrack: MediaStream?) {
        guard let pendingResolution else { return }
        isShowingAudioPrompt = false

        let defaultSubtitle = pendingResolution.subtitleTracks.first { $0.isDefault == true }
            ?? pendingResolution.subtitleTracks.first { $0.isForced == true }
        if let defaultSubtitle, JellyfinAPIClient.isImageBasedSubtitleCodec(defaultSubtitle.codec) {
            isShowingSubtitleWarning = true
            return
        }

        Task {
            await enqueue(mediaSource: pendingResolution.mediaSource, audioTrack: audioTrack, subtitleTracks: pendingResolution.subtitleTracks)
        }
    }

    private func enqueue(mediaSource: MediaSourceInfo, audioTrack: MediaStream?, subtitleTracks: [MediaStream]) async {
        defer { pendingResolution = nil }
        do {
            try await downloadManager.enqueue(
                item: item, mediaSource: mediaSource, audioTrack: audioTrack, subtitleTracks: subtitleTracks,
                resolution: preferences.resolution, preset: preferences.bitratePreset,
                client: client, userID: userID
            )
        } catch {
            presentError((error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't start the download."))
        }
    }
}
