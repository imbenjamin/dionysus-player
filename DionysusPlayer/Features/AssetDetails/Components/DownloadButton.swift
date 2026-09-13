import SwiftUI

/// Starts an offline download of `item`, placed near `PlayResumeButtonRow` on
/// the detail page. Fetches `playbackInfo` for the item's audio/subtitle tracks
/// (not on the detail page's own dto), prompts for an audio track when there's
/// more than one, warns if proceeding would leave the download without its
/// default/forced subtitle track (image-based tracks can't go offline — see
/// `JellyfinAPIClient.isImageBasedSubtitleCodec`), then hands off to
/// `DownloadManager.enqueue`.
///
/// Quality and resolution come from `DownloadPreferencesStore` by default; a
/// long-press on the idle button presents `AdvancedDownloadOptionsView` to
/// override them for this one download (`overrideResolution`/`overridePreset`).
/// The rest of the flow is identical either way.
struct DownloadButton: View {
    /// Which chrome this renders with. The state logic below is identical
    /// either way; only the visual weight differs.
    enum Style {
        /// The bordered-prominent chip next to Play/Resume/Restart.
        case prominent
        /// A circular badge, matching the black-circle/white-icon Play button
        /// it sits alongside in `EpisodeRow`, for overlaying on artwork where
        /// `.prominent`'s chip chrome reads as too heavy.
        case overlay
    }

    let item: MediaItem
    let client: JellyfinAPIClient
    let userID: String
    let downloadManager: DownloadManager
    var style: Style = .prominent
    /// Appended to the state label ("Download, S19:E6") for call sites where
    /// several of these appear together and the state word alone wouldn't say
    /// which item it's for, such as `SeasonEpisodeList`'s per-episode overlay
    /// buttons. `nil` leaves the bare state word, correct for the single
    /// page-level button.
    var accessibilityContext: String? = nil

    private let preferences = DownloadPreferencesStore()
    private let trackPreferenceStore = TrackPreferenceStore()

    @State private var isResolving = false
    @State private var pendingResolution: PendingDownload?
    @State private var isShowingAudioPrompt = false
    @State private var isShowingSubtitleWarning = false
    @State private var isShowingError = false
    @State private var errorMessage = ""
    @State private var isShowingAdvancedOptions = false
    /// Flipped, never read, whenever the long-press below recognizes:
    /// `.sensoryFeedback(_:trigger:)` fires on any change of its trigger.
    @State private var advancedOptionsHapticTrigger = false
    /// Set by `AdvancedDownloadOptionsView`'s "Download" action, read and
    /// cleared by `enqueue(mediaSource:audioTrack:subtitleTracks:)` in place of
    /// `preferences.resolution`/`.bitratePreset`. `nil` otherwise, so a plain
    /// tap falls through to the device-wide preference.
    @State private var overrideResolution: DownloadResolution?
    @State private var overridePreset: DownloadBitratePreset?

    /// What's been resolved from `playbackInfo` so far, waiting on the
    /// audio-track prompt before `beginDownload(audioTrack:)` can enqueue.
    private struct PendingDownload {
        var mediaSource: MediaSourceInfo
        var audioTracks: [MediaStream]
        var subtitleTracks: [MediaStream]
        /// Set by `resolveAudioTrack(_:)` once the track is known, whether
        /// picked from the prompt or defaulted. The subtitle warning's
        /// "Download Anyway" reads this rather than `audioTracks.first`, which
        /// would discard the user's choice.
        var chosenAudioTrack: MediaStream? = nil
        /// The track in `audioTracks` best matching what `TrackPreferenceStore`
        /// remembers the user picking for this item during live playback.
        /// Computed once in `startResolving()` and only marked in the prompt,
        /// never auto-applied — the baked-in track is always an explicit tap.
        var rememberedAudioTrackIndex: Int? = nil
    }

    /// `_ = downloadManager.store.changeCount` establishes an
    /// Observation-tracked dependency: `store.item(itemID:)` is a raw SwiftData
    /// fetch, not a tracked property read, so without it this view stops
    /// re-rendering when the row changes elsewhere. See
    /// `DownloadStore.changeCount`.
    private var downloadedRow: DownloadedItem? {
        _ = downloadManager.store.changeCount
        return downloadManager.store.item(itemID: item.id)
    }

    /// Live byte progress while a download is in flight; `nil` before and
    /// after, including while `isResolving`/`isPreparing`, which precede the
    /// download and have no byte count.
    ///
    /// `progress`/`isPreparing`/`isPendingDeletion`/`isDownloaded`/`isBusy` each
    /// take `row` explicitly, with a zero-arg twin that calls the same form
    /// against a fresh `downloadedRow` fetch. `content` fetches the row once and
    /// threads it through, rather than each property re-querying SwiftData. The
    /// zero-arg forms exist for the long-press completion closure below, which
    /// fires long after the last render and needs a fresh fetch.
    private func progress(for row: DownloadedItem?) -> DownloadProgress? {
        guard let row, row.status == .downloading || row.status == .queued else { return nil }
        return downloadManager.activeDownloads[item.id]
    }
    private var progress: DownloadProgress? { progress(for: downloadedRow) }

    /// The row exists and is queued/downloading, but the background video task
    /// isn't reporting byte progress yet: `DownloadManager.enqueue` fetches the
    /// metadata/artwork snapshot and subtitle sidecars first, routinely a second
    /// or more. Distinct from `isResolving`, the earlier `playbackInfo`
    /// fetch/prompt phase. Without it the button shows its idle icon here,
    /// indistinguishable from not downloading.
    private func isPreparing(for row: DownloadedItem?) -> Bool {
        guard let row, row.status == .downloading || row.status == .queued else { return false }
        return downloadManager.activeDownloads[item.id] == nil
    }
    private var isPreparing: Bool { isPreparing(for: downloadedRow) }

    private var isDownloading: Bool {
        downloadManager.activeDownloads[item.id] != nil
    }
    /// A deleted row still carrying an unsynced watched/resume write (see
    /// `DownloadManager.delete(itemID:)`): its files are gone, but
    /// `downloadedRow` still finds it and delete leaves `status` untouched,
    /// typically `.completed`. Separate from `isDownloaded` so this button
    /// doesn't show a checkmark and navigate to a broken detail page.
    private func isPendingDeletion(for row: DownloadedItem?) -> Bool {
        row?.markedForDeletion == true
    }
    private var isPendingDeletion: Bool { isPendingDeletion(for: downloadedRow) }

    private func isDownloaded(for row: DownloadedItem?) -> Bool {
        row?.status == .completed && !isPendingDeletion(for: row)
    }
    private var isDownloaded: Bool { isDownloaded(for: downloadedRow) }

    /// Everything that should block a second tap: resolving, preparing,
    /// downloading, or a `markedForDeletion` row awaiting its pending sync.
    /// A fresh download would race a row this button doesn't own.
    private func isBusy(for row: DownloadedItem?) -> Bool {
        isResolving || isPreparing(for: row) || isDownloading || isPendingDeletion(for: row)
    }
    private var isBusy: Bool { isBusy(for: downloadedRow) }

    /// Matches `PlayResumeButtonRow`'s "Restart" button: same
    /// bordered-prominent/rounded-rect/large/light-tint shape, and no explicit
    /// `.frame`, so the system sizes it around its glyph rather than as a fixed
    /// square, reading as a peer transport action.
    private let cornerRadius: CGFloat = 12
    /// Only the progress ring needs an explicit size, having no intrinsic one
    /// unlike an SF Symbol — picked to match Restart's glyph at `.large`.
    private let ringSize: CGFloat = 20

    /// White on the `.overlay` badge, matching the Play button on the same
    /// black circle; brand primary on the `.prominent` chip, matching
    /// Restart and the checkmark elsewhere on the detail page.
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
                    Button(audioTrackButtonLabel(for: track, pendingResolution: pendingResolution)) {
                        resolveAudioTrack(track)
                    }
                }
            }
            // Explicit rather than relying on the implicit dismiss, which
            // flips `isShowingAudioPrompt` false but calls no handler, leaving
            // the overrides dangling — the bug `presentError` describes.
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
            // Same reset, same reason, as the audio-track dialog's Cancel.
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
                initialPreset: preferences.bitratePreset,
                sourceWidth: sourceVideoStream?.width,
                sourceHeight: sourceVideoStream?.height,
                sourceBitrate: sourceVideoStream?.bitRate ?? sourceMediaSource?.bitrate,
                isSourceHDR: DownloadManager.isHDR(sourceVideoStream),
                sourceVideoCodec: sourceVideoStream?.codec,
                runtimeTicks: item.dto.runTimeTicks
            ) { resolution, preset in
                overrideResolution = resolution
                overridePreset = preset
                startResolving()
            }
        }
    }

    /// The item's detail-page media source, reused for the Advanced Options
    /// size estimate. `item.dto.mediaSources` is already populated by the
    /// `detailFields` fetch that loaded this page, so this needs no fetch of
    /// its own — unlike `startResolving()`'s `playbackInfo` call, which exists
    /// for the audio/subtitle tracks the dto lacks. Both can be stale only if
    /// the source changed server-side since the page loaded, acceptable for an
    /// estimate.
    private var sourceMediaSource: MediaSourceInfo? { item.dto.mediaSources?.first }
    private var sourceVideoStream: MediaStream? { sourceMediaSource?.mediaStreams?.first { $0.type == "Video" } }

    /// "S1:E4 · Pilot" for an episode, the plain title otherwise — the same
    /// per-type formatting as `MediaItem.railSubtitle`.
    private var advancedOptionsTitle: String {
        item.episodeLabel.map { "\($0) \u{00B7} \(item.name)" } ?? item.name
    }

    /// The tap target and state icon, identical between styles; only the chrome
    /// around it differs.
    @ViewBuilder
    private var content: some View {
        // Fetched once per render and threaded through the parameterized forms
        // below — see `downloadedRow`.
        let row = downloadedRow
        if isDownloaded(for: row) {
            // Already downloaded: a second tap opens the download's page to
            // play, inspect or delete it, rather than re-downloading.
            NavigationLink(value: AppRoute.downloadedAsset(itemID: item.id)) {
                badge { Image(systemName: "checkmark.circle.fill").foregroundStyle(iconColor) }
            }
            .accessibilityLabel(withContext(String(localized: "Downloaded")))
            .accessibilityIdentifier(A11yID.AssetDetail.downloadButton)
        } else {
            Button(action: startResolving) {
                if let progress = progress(for: row) {
                    badge { DownloadProgressRing(progress: progress, tint: iconColor) }
                } else if isResolving || isPreparing(for: row) || isPendingDeletion(for: row) {
                    // A plain spinner, not the progress ring: there's no byte
                    // progress yet (see `isPreparing`), and a ring at 0% reads
                    // as stuck rather than starting. `isPendingDeletion` rides
                    // the same spinner — the button is disabled either way, but
                    // the idle icon reads as ready to tap, which a
                    // `markedForDeletion` row isn't.
                    badge { ProgressView().tint(iconColor) }
                } else {
                    badge { Image(systemName: "arrow.down.circle").foregroundStyle(iconColor) }
                }
            }
            .disabled(isBusy(for: row))
            .accessibilityLabel(accessibilityLabel(for: row))
            .accessibilityIdentifier(A11yID.AssetDetail.downloadButton)
            // Hold instead of tap: the same `startResolving` flow, entered via
            // `AdvancedDownloadOptionsView`. `.highPriorityGesture` rather than
            // `.onLongPressGesture`, which doesn't suppress the `Button`'s own
            // tap once the hold completes, so both fired.
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    guard !isBusy else { return }
                    advancedOptionsHapticTrigger.toggle()
                    isShowingAdvancedOptions = true
                }
            )
            // The medium-weight impact UIKit fires for its own long-press
            // recognitions (context menus, reordering, icon jiggle).
            .sensoryFeedback(.impact, trigger: advancedOptionsHapticTrigger)
        }
    }

    /// Mirrors `content`'s idle/preparing/downloading state icons. The
    /// `isDownloaded` `NavigationLink` branch sets its own "Downloaded" label
    /// at its call site, being a structurally different element.
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

    /// See `accessibilityContext`.
    private func withContext(_ state: String) -> String {
        guard let accessibilityContext else { return state }
        return String(localized: "\(state), \(accessibilityContext)")
    }

    /// Wraps the state icon/spinner/ring in the fixed-size container `style`
    /// calls for. Always fixed, because `Image(systemName:)`, `ProgressView()`
    /// and `DownloadProgressRing` each report a different natural size —
    /// `ProgressView()` renders larger than an SF Symbol at this control size —
    /// so the button's footprint popped on every state change.
    @ViewBuilder
    private func badge<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        switch style {
        case .prominent:
            inner().frame(width: ringSize, height: ringSize)
        case .overlay:
            // Same black-circle/white-icon treatment as `EpisodeRow`'s Play
            // button, at 32pt against its 36pt so it reads as secondary.
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
                var resolution = PendingDownload(mediaSource: mediaSource, audioTracks: audioTracks, subtitleTracks: subtitleTracks)
                resolution.rememberedAudioTrackIndex = Self.rememberedAudioTrackIndex(
                    among: audioTracks, storedPreference: trackPreferenceStore.selection(forItem: item.id, userID: userID)?.audioTrack
                )
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

    /// Finds whichever of `audioTracks` is most likely the one named by a
    /// `TrackPreferenceStore` entry from a previous live playback session, so
    /// the prompt can flag it. Informational only, never auto-applied.
    ///
    /// Can't reuse `PlayerViewModel.applyStoredTrackSelection()`'s stricter
    /// id-and-title check: that compares against `engine.audioTracks`, whose
    /// ids are AetherEngine's physical container positions and whose titles come
    /// from container metadata — a different id space and vocabulary from the
    /// `MediaStream.index`/`.displayTitle` here, which come straight from
    /// Jellyfin's `PlaybackInfo`. So this matches on title alone, and loosely
    /// (case-insensitive substring), since Jellyfin's `displayTitle` is
    /// typically a decorated superset of the bare language name AetherEngine
    /// reduces to — "English - AC3 5.1" against a stored "English". A miss just
    /// means no hint, and the user still taps to choose.
    private static func rememberedAudioTrackIndex(
        among audioTracks: [MediaStream], storedPreference: TrackPreferenceStore.TrackChoice?
    ) -> Int? {
        guard let storedPreference, !storedPreference.title.isEmpty else { return nil }
        return audioTracks.first { track in
            let label = track.displayTitle ?? track.title ?? ""
            return label.localizedCaseInsensitiveContains(storedPreference.title)
        }?.index
    }

    /// The matched track gets an explicit text suffix rather than a checkmark:
    /// `confirmationDialog` buttons are plain strings, with no room for a
    /// caption view or a color-only treatment VoiceOver would miss.
    private func audioTrackButtonLabel(for track: MediaStream, pendingResolution: PendingDownload) -> String {
        let title = track.displayTitle ?? String(localized: "Track \(track.index + 1)")
        guard track.index == pendingResolution.rememberedAudioTrackIndex else { return title }
        return String(localized: "\(title) (Previously selected)")
    }

    /// Also resets `pendingResolution`/`overrideResolution`/`overridePreset`,
    /// otherwise only cleared in
    /// `enqueue(mediaSource:audioTrack:subtitleTracks:)`'s `defer`: an
    /// advanced-options attempt that aborted before reaching it would leave
    /// them on this view's `@State`, and a later plain tap would reuse that
    /// stale override instead of the device-wide preference.
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
        // `AdvancedDownloadOptionsView`'s "Download" action and this call.
        // Cleared regardless of outcome, so a later plain tap doesn't reuse a
        // stale one-off choice.
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
