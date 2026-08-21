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
/// from `DownloadPreferencesStore` (`ProfileView`'s Downloads settings) by
/// default; a long-press on the idle button instead presents
/// `AdvancedDownloadOptionsView` to override resolution/quality for this one
/// download only (`overrideResolution`/`overridePreset` below) — everything
/// else in the flow (audio prompt, subtitle warning, enqueue) is identical
/// either way.
struct DownloadButton: View {
    /// Which chrome this renders with — the *state* logic below (idle/
    /// resolving/preparing/downloading/downloaded, prompts, errors) is
    /// identical either way; only the visual weight differs.
    enum Style {
        /// The bordered-prominent chip next to Play/Resume/Restart at the
        /// top of the detail page.
        case prominent
        /// A subtle circular badge — the same black-circle/white-icon
        /// treatment as the video-thumbnail Play button it sits alongside
        /// in `EpisodeRow` — for when this is overlaid directly on artwork
        /// instead of sitting in a plain row next to other bordered
        /// buttons. Confirmed live (2026-08-19) that reusing `.prominent`'s
        /// heavy chip chrome there read as far too heavy against a thumbnail.
        case overlay
    }

    let item: MediaItem
    let client: JellyfinAPIClient
    let userID: String
    let downloadManager: DownloadManager
    var style: Style = .prominent

    private let preferences = DownloadPreferencesStore()

    @State private var isResolving = false
    @State private var pendingResolution: PendingDownload?
    @State private var isShowingAudioPrompt = false
    @State private var isShowingSubtitleWarning = false
    @State private var isShowingError = false
    @State private var errorMessage = ""
    @State private var isShowingAdvancedOptions = false
    /// Flipped (never read directly) every time the long-press below
    /// recognizes — `.sensoryFeedback(_:trigger:)` fires on each *change*
    /// of its trigger value, not on a particular value, so a plain toggle
    /// is all this needs to be.
    @State private var advancedOptionsHapticTrigger = false
    /// Set by `AdvancedDownloadOptionsView`'s "Download" action, read (and
    /// cleared) by `enqueue(mediaSource:audioTrack:subtitleTracks:)` in
    /// place of `preferences.resolution`/`.bitratePreset` — `nil` the rest
    /// of the time, which is what makes a plain tap fall through to the
    /// normal device-wide preference unchanged.
    @State private var overrideResolution: DownloadResolution?
    @State private var overridePreset: DownloadBitratePreset?

    /// What's been resolved from `playbackInfo` so far, waiting on the
    /// audio-track prompt (if any) before `beginDownload(audioTrack:)` can
    /// actually enqueue.
    private struct PendingDownload {
        var mediaSource: MediaSourceInfo
        var audioTracks: [MediaStream]
        var subtitleTracks: [MediaStream]
    }

    /// `_ = downloadManager.store.changeCount` establishes a real,
    /// Observation-tracked dependency — `store.item(itemID:)` itself is a
    /// raw SwiftData fetch, not a tracked property read, so without this
    /// this view could silently stop re-rendering when the row changed
    /// from somewhere else entirely (a real bug, found live 2026-08-20 —
    /// see `DownloadStore.changeCount`'s own doc comment).
    private var downloadedRow: DownloadedItem? {
        _ = downloadManager.store.changeCount
        return downloadManager.store.item(itemID: item.id)
    }

    /// Live byte progress while a download for this item is actually in
    /// flight — `nil` before/after, including while `isResolving`/
    /// `isPreparing` (both precede an actual download and have no byte
    /// count of their own to show).
    ///
    /// `progress`/`isPreparing`/`isPendingDeletion`/`isDownloaded`/`isBusy`
    /// each take `row` as an explicit parameter, with a matching zero-arg
    /// computed property that just calls the parameterized form against a
    /// *fresh* `downloadedRow` fetch — a real inefficiency, found in a
    /// 2026-08-20 branch review: `content` below used to call the zero-arg
    /// properties directly, each independently re-querying
    /// `downloadManager.store.item(itemID:)` (a real SwiftData fetch, not a
    /// dictionary lookup) — up to ~5-7 redundant queries for the exact same
    /// row within a single render pass. `content` now fetches `downloadedRow`
    /// once and threads it through the parameterized forms instead; the
    /// zero-arg properties survive only for the long-press gesture's
    /// completion closure below, which fires well after the view was last
    /// rendered and needs a *fresh* re-fetch at that later moment, not a
    /// stale render-time snapshot (the same "closures should read live
    /// state at call time" lesson this app's toolbar-button bug already
    /// established elsewhere).
    private func progress(for row: DownloadedItem?) -> DownloadProgress? {
        guard let row, row.status == .downloading || row.status == .queued else { return nil }
        return downloadManager.activeDownloads[item.id]
    }
    private var progress: DownloadProgress? { progress(for: downloadedRow) }

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
    private func isPreparing(for row: DownloadedItem?) -> Bool {
        guard let row, row.status == .downloading || row.status == .queued else { return false }
        return downloadManager.activeDownloads[item.id] == nil
    }
    private var isPreparing: Bool { isPreparing(for: downloadedRow) }

    private var isDownloading: Bool {
        downloadManager.activeDownloads[item.id] != nil
    }
    /// A row that's been deleted but still has an unsynced watched/resume
    /// write to carry (see the offline-downloads plan's "Delete semantics"
    /// section) — its files are already gone, but `downloadedRow` above
    /// still finds the row itself (a raw, unfiltered lookup), and the row's
    /// own `status` is untouched by delete, still whatever it was before
    /// (typically `.completed`). A real bug, found live (2026-08-20):
    /// without accounting for this separately, `isDownloaded` below read
    /// `true` for a `markedForDeletion` row, so this button kept showing
    /// the "already downloaded" checkmark and navigating to a now-broken
    /// `DownloadedAssetDetailView` (its video file already gone) until
    /// `DownloadSyncManager` finally got a chance to push the pending sync
    /// and let `DownloadManager.delete(itemID:)`'s next pass remove the row
    /// for real — which can take a while, since that sync is only
    /// triggered on app-foreground/reconnect, not on any fixed timer.
    private func isPendingDeletion(for row: DownloadedItem?) -> Bool {
        row?.markedForDeletion == true
    }
    private var isPendingDeletion: Bool { isPendingDeletion(for: downloadedRow) }

    private func isDownloaded(for row: DownloadedItem?) -> Bool {
        row?.status == .completed && !isPendingDeletion(for: row)
    }
    private var isDownloaded: Bool { isDownloaded(for: downloadedRow) }

    /// Everything that should block a second tap — resolving, preparing,
    /// actively downloading, or a `markedForDeletion` row still waiting on
    /// its pending sync to actually go away (see `isPendingDeletion`'s own
    /// doc comment — tapping through to a fresh download here would race a
    /// row this button doesn't own the lifecycle of). `isResolving ||
    /// isDownloading` alone (the original condition) left the button
    /// tappable again during the `isPreparing` window above, which could
    /// fire a second, redundant `enqueue` for the same item.
    private func isBusy(for row: DownloadedItem?) -> Bool {
        isResolving || isPreparing(for: row) || isDownloading || isPendingDeletion(for: row)
    }
    private var isBusy: Bool { isBusy(for: downloadedRow) }

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

    /// White on the `.overlay` badge (matching the Play button's own
    /// white icon on the same black circle), the brand primary color on
    /// the `.prominent` chip (matching Restart/checkmark elsewhere on the
    /// detail page).
    private var iconColor: Color { style == .overlay ? .white : Color.dionysusPrimary }

    var body: some View {
        Group {
            switch style {
            case .prominent:
                content
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
                    .tint(.dionysusPrimaryLight)
                    .controlSize(.large)
            case .overlay:
                content
                    .buttonStyle(.plain)
            }
        }
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
            // Explicit, not relying on the system's own implicit dismiss —
            // that dismiss flips `isShowingAudioPrompt` false but calls no
            // handler at all, which is exactly the "overrides left
            // dangling on an abandoned attempt" bug `presentError`'s own
            // doc comment describes; this is the same reset, for the same
            // reason, on this dialog's own cancel path.
            Button("Cancel", role: .cancel) {
                pendingResolution = nil
                overrideResolution = nil
                overridePreset = nil
            }
        }
        .alert("Subtitle Track Unavailable Offline", isPresented: $isShowingSubtitleWarning) {
            Button("Download Anyway") {
                if let pendingResolution {
                    Task { await enqueue(mediaSource: pendingResolution.mediaSource, audioTrack: pendingResolution.audioTracks.first, subtitleTracks: pendingResolution.subtitleTracks) }
                }
            }
            // See the audio-track dialog's own Cancel button just above —
            // same reset, same reason.
            Button("Cancel", role: .cancel) {
                pendingResolution = nil
                overrideResolution = nil
                overridePreset = nil
            }
        } message: {
            Text("This title's default subtitle track can't be included in offline downloads. The download will have no subtitles unless you choose one manually later.")
        }
        .alert("Couldn't Start Download", isPresented: $isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $isShowingAdvancedOptions) {
            AdvancedDownloadOptionsView(
                itemTitle: advancedOptionsTitle,
                initialResolution: preferences.resolution,
                initialPreset: preferences.bitratePreset
            ) { resolution, preset in
                overrideResolution = resolution
                overridePreset = preset
                startResolving()
            }
        }
    }

    /// e.g. "S1:E4 · Pilot" for an episode, the plain title otherwise —
    /// same per-type formatting `MediaItem.railSubtitle` already uses, so
    /// this reads as the same kind of label the rest of the app shows for
    /// this item rather than inventing a new convention just for this sheet.
    private var advancedOptionsTitle: String {
        item.episodeLabel.map { "\($0) \u{00B7} \(item.name)" } ?? item.name
    }

    /// The actual tap target/state icon — identical between styles, see
    /// `body`'s own doc comment for why only the chrome around this
    /// differs.
    @ViewBuilder
    private var content: some View {
        // Fetched once per render and threaded through the parameterized
        // forms below, rather than each of `isDownloaded`/`progress`/
        // `isPreparing`/`isPendingDeletion`/`isBusy` independently
        // re-querying SwiftData for the same row — see `downloadedRow`'s
        // own doc comment above for the real cost this used to have.
        let row = downloadedRow
        if isDownloaded(for: row) {
            // Already downloaded — a second tap should open the
            // download's own page (to play it offline, check its size, or
            // delete it), not silently re-download the same item from
            // scratch.
            NavigationLink(value: AppRoute.downloadedAsset(itemID: item.id)) {
                badge { Image(systemName: "checkmark.circle.fill").foregroundStyle(iconColor) }
            }
        } else {
            Button(action: startResolving) {
                if let progress = progress(for: row) {
                    badge { DownloadProgressRing(progress: progress, tint: iconColor) }
                } else if isResolving || isPreparing(for: row) || isPendingDeletion(for: row) {
                    // A plain spinner, not the progress ring — there's no
                    // determined byte progress yet to show as one (see
                    // `isPreparing`'s own doc comment), and an
                    // indeterminate ring at 0% reads as "stuck", not
                    // "starting". `isPendingDeletion` rides the same
                    // spinner rather than the plain idle icon below — this
                    // button is disabled either way (`isBusy`), but the
                    // idle icon specifically reads as "ready to tap",
                    // which a `markedForDeletion` row isn't yet.
                    badge { ProgressView().tint(iconColor) }
                } else {
                    badge { Image(systemName: "arrow.down.circle").foregroundStyle(iconColor) }
                }
            }
            .disabled(isBusy(for: row))
            // Hold instead of tap: same idle button, different entry point
            // into the same resolve/prompt/enqueue flow (`startResolving`)
            // — see `AdvancedDownloadOptionsView`'s own doc comment.
            // `.highPriorityGesture`, not a plain `.onLongPressGesture` —
            // confirmed live (2026-08-19, RocketSim + Simulator) that a
            // bare `.onLongPressGesture` attached to a `Button` doesn't
            // suppress the Button's own tap action once the hold completes;
            // both fired, so a long-press opened the advanced sheet *and*
            // immediately started a plain-preference download underneath
            // it. `.highPriorityGesture` is the documented mechanism for a
            // gesture that should win outright over a view's own built-in
            // one, rather than compete alongside it — the Button's tap only
            // fires when this one fails to recognize (a genuinely short
            // tap), never both.
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    guard !isBusy else { return }
                    advancedOptionsHapticTrigger.toggle()
                    isShowingAdvancedOptions = true
                }
            )
            // The same medium-weight impact UIKit fires for its own
            // long-press-recognized moments (context menus, reordering,
            // icon-jiggle entry) — matches the system feel rather than
            // inventing a bespoke one for this one gesture.
            .sensoryFeedback(.impact, trigger: advancedOptionsHapticTrigger)
        }
    }

    /// Wraps the state icon/spinner/ring in whatever fixed-size container
    /// `style` calls for. Always a fixed frame regardless of style — a
    /// plain `Image(systemName:)`, a bare `ProgressView()`, and
    /// `DownloadProgressRing` each report a different natural size to
    /// their parent when left unconstrained (`ProgressView()` in
    /// particular renders noticeably larger than an SF Symbol glyph at
    /// this control size), so without one the button's own footprint
    /// visibly popped to a different size for a frame or two on every
    /// state change — confirmed live (2026-08-19) — before settling back
    /// once the new content re-laid-out.
    @ViewBuilder
    private func badge<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        switch style {
        case .prominent:
            inner().frame(width: ringSize, height: ringSize)
        case .overlay:
            // Same black-circle/white-icon treatment as the video
            // thumbnail's own Play button (`EpisodeRow`), sized a touch
            // smaller (32pt vs. Play's 36pt) so it reads as the
            // secondary/corner action next to it.
            inner()
                .frame(width: 16, height: 16)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.black.opacity(0.55)))
        }
    }

    private func startResolving() {
        guard !isResolving, !isDownloading else { return }
        withAnimation { isResolving = true }
        Task {
            defer { withAnimation { isResolving = false } }
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

    /// Also resets `pendingResolution`/`overrideResolution`/`overridePreset`
    /// — a real bug found live (2026-08-20): those two only ever got
    /// cleared inside `enqueue(mediaSource:audioTrack:subtitleTracks:)`'s
    /// own `defer`, so an advanced-options attempt that set them and then
    /// aborted *before* reaching that point (this method being called from
    /// `startResolving()`'s own failure paths, a subtitle-warning
    /// dismissal, or an audio-track-picker dismissal — see those calls
    /// sites' own comments) left them dangling on this view's `@State`
    /// indefinitely. A *later*, unrelated plain tap on the same button
    /// then silently reused that stale one-off override instead of the
    /// live device-wide preference — confirmed live: a plain tap after an
    /// earlier abandoned "480p / Data Saver" advanced attempt produced a
    /// 480p / Data Saver download despite the device preference reading
    /// 1080p / Normal.
    private func presentError(_ message: String) {
        pendingResolution = nil
        overrideResolution = nil
        overridePreset = nil
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
        // `overrideResolution`/`overridePreset` only carry a value between
        // `AdvancedDownloadOptionsView`'s "Download" action and this call —
        // cleared here regardless of outcome so a later *plain* tap (after
        // a cancelled/failed advanced download) doesn't silently reuse a
        // stale one-off choice instead of falling back to the real
        // preference again.
        defer { pendingResolution = nil; overrideResolution = nil; overridePreset = nil }
        do {
            try await downloadManager.enqueue(
                item: item, mediaSource: mediaSource, audioTrack: audioTrack, subtitleTracks: subtitleTracks,
                resolution: overrideResolution ?? preferences.resolution, preset: overridePreset ?? preferences.bitratePreset,
                client: client, userID: userID
            )
        } catch {
            presentError((error as? LocalizedError)?.errorDescription ?? String(localized: "Couldn't start the download."))
        }
    }
}
