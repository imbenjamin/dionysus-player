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
        /// buttons; `.prominent`'s heavy chip chrome reads as too heavy
        /// against a thumbnail.
        case overlay
    }

    let item: MediaItem
    let client: JellyfinAPIClient
    let userID: String
    let downloadManager: DownloadManager
    var style: Style = .prominent
    /// Appended to this button's own state label — e.g. "Download, S19:E6"
    /// instead of a bare "Download" — for call sites where several of these
    /// appear together and the state word alone wouldn't say which item
    /// it's for (`SeasonEpisodeList`'s per-episode `.overlay` buttons).
    /// `nil` (the default) leaves the label as just the state word, correct
    /// for the single page-level `.prominent` button next to Play/Resume,
    /// where which item it's for is already unambiguous from the page
    /// itself.
    var accessibilityContext: String? = nil

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
        /// Set by `resolveAudioTrack(_:)` as soon as the audio track is
        /// known (whether picked from the prompt or defaulted with only
        /// one available) — the subtitle-warning alert's "Download Anyway"
        /// button reads this rather than `audioTracks.first`, which would
        /// otherwise silently discard whatever the user actually chose.
        var chosenAudioTrack: MediaStream? = nil
    }

    /// `_ = downloadManager.store.changeCount` establishes a real,
    /// Observation-tracked dependency — `store.item(itemID:)` itself is a
    /// raw SwiftData fetch, not a tracked property read, so without this
    /// this view could silently stop re-rendering when the row changed
    /// from somewhere else entirely (see `DownloadStore.changeCount`'s own
    /// doc comment).
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
    /// fresh `downloadedRow` fetch. `content` below fetches `downloadedRow`
    /// once and threads it through the parameterized forms, rather than
    /// each property independently re-querying SwiftData for the same row;
    /// the zero-arg properties survive only for the long-press gesture's
    /// completion closure below, which fires well after the view was last
    /// rendered and needs a fresh re-fetch, not a stale render-time
    /// snapshot.
    private func progress(for row: DownloadedItem?) -> DownloadProgress? {
        guard let row, row.status == .downloading || row.status == .queued else { return nil }
        return downloadManager.activeDownloads[item.id]
    }
    private var progress: DownloadProgress? { progress(for: downloadedRow) }

    /// The `DownloadedItem` row exists and is queued/downloading, but the
    /// background video task hasn't started reporting real byte progress
    /// yet — `DownloadManager.enqueue` spends real time up front (fetching
    /// the metadata/artwork snapshot, subtitle sidecars) before the video
    /// task itself starts, so this window is routinely a second or more.
    /// Distinct from `isResolving` (the earlier `playbackInfo`-fetch/prompt
    /// phase) — without it, the button fell through to its plain idle icon
    /// here, indistinguishable from "not downloading at all."
    private func isPreparing(for row: DownloadedItem?) -> Bool {
        guard let row, row.status == .downloading || row.status == .queued else { return false }
        return downloadManager.activeDownloads[item.id] == nil
    }
    private var isPreparing: Bool { isPreparing(for: downloadedRow) }

    private var isDownloading: Bool {
        downloadManager.activeDownloads[item.id] != nil
    }
    /// A row that's been deleted but still has an unsynced watched/resume
    /// write to carry (see `DownloadManager.delete(itemID:)`'s doc comment)
    /// — its files are already gone, but `downloadedRow` above still finds
    /// the row itself, and its `status` is untouched by delete (typically
    /// still `.completed`). Tracked separately from `isDownloaded` so this
    /// button doesn't show the "already downloaded" checkmark and navigate
    /// to a now-broken detail page for a row whose files are already gone.
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
    /// its pending sync (see `isPendingDeletion`) — tapping through to a
    /// fresh download would race a row this button doesn't own the
    /// lifecycle of.
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
                    Task { await enqueue(mediaSource: pendingResolution.mediaSource, audioTrack: pendingResolution.chosenAudioTrack, subtitleTracks: pendingResolution.subtitleTracks) }
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
        // forms below — see `downloadedRow`'s own doc comment.
        let row = downloadedRow
        if isDownloaded(for: row) {
            // Already downloaded — a second tap should open the
            // download's own page (to play it offline, check its size, or
            // delete it), not silently re-download the same item from
            // scratch.
            NavigationLink(value: AppRoute.downloadedAsset(itemID: item.id)) {
                badge { Image(systemName: "checkmark.circle.fill").foregroundStyle(iconColor) }
            }
            .accessibilityLabel(withContext(String(localized: "Downloaded")))
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
            .accessibilityLabel(accessibilityLabel(for: row))
            // Hold instead of tap: same idle button, different entry point
            // into the same resolve/prompt/enqueue flow (`startResolving`)
            // — see `AdvancedDownloadOptionsView`'s own doc comment.
            // `.highPriorityGesture`, not a plain `.onLongPressGesture` — a
            // bare `.onLongPressGesture` on a `Button` doesn't suppress the
            // Button's own tap once the hold completes, so both fired.
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

    /// Mirrors `content`'s own idle/preparing/downloading state icons — see
    /// that view's doc comment for what each covers. `isDownloaded`'s own
    /// `NavigationLink` branch has its own separate `"Downloaded"` label
    /// set directly at its call site, since it's structurally a different
    /// element from this one.
    private func accessibilityLabel(for row: DownloadedItem?) -> String {
        let state: String
        if let progress = progress(for: row) {
            state = progress.statusText
        } else if isResolving || isPreparing(for: row) || isPendingDeletion(for: row) {
            state = String(localized: "Preparing Download")
        } else {
            state = String(localized: "Download")
        }
        return withContext(state)
    }

    /// See `accessibilityContext`'s own doc comment.
    private func withContext(_ state: String) -> String {
        guard let accessibilityContext else { return state }
        return String(localized: "\(state), \(accessibilityContext)")
    }

    /// Wraps the state icon/spinner/ring in whatever fixed-size container
    /// `style` calls for. Always a fixed frame regardless of style — a
    /// plain `Image(systemName:)`, a bare `ProgressView()`, and
    /// `DownloadProgressRing` each report a different natural size when
    /// left unconstrained (`ProgressView()` in particular renders larger
    /// than an SF Symbol glyph at this control size), so without one the
    /// button's footprint visibly popped between sizes on every state
    /// change before settling back.
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
    /// — those two are otherwise only cleared inside
    /// `enqueue(mediaSource:audioTrack:subtitleTracks:)`'s own `defer`, so
    /// an advanced-options attempt that set them and then aborted before
    /// reaching that point would leave them dangling on this view's
    /// `@State`, and a later, unrelated plain tap would silently reuse that
    /// stale one-off override instead of the live device-wide preference.
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
        self.pendingResolution?.chosenAudioTrack = audioTrack

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
