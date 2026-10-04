import SwiftUI

/// Downloads settings, split out of `ProfileView` once the section grew a storage
/// graph alongside its quality and network pickers — the iOS Settings pattern of
/// a summary row pushing to a dedicated sub-screen.
///
/// Reached only from `ProfileView`, via a plain `NavigationLink(destination:)`
/// rather than a new `AppRoute` case: `AppRoute` is for destinations pushed from
/// more than one feature's stack.
///
/// On iPad it isn't pushed at all but is the root of the Downloads pane in
/// `ProfileView`'s split layout, hence `titleDisplayMode`: a pushed sub-screen
/// wants `.inline`, but as a pane root it sits alongside Appearance/Playback/About,
/// which all get a large title.
struct DownloadsSettingsView: View {
    /// `.inline` when pushed, `.large` when it is the pane. See the type's doc
    /// comment.
    var titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline

    /// Default must stay in lockstep with
    /// `DownloadPreferencesStore.resolution`'s fallback.
    @AppStorage(downloadResolutionStorageKey) private var downloadResolution: DownloadResolution = .deviceClassDefault
    @AppStorage(downloadBitratePresetStorageKey) private var downloadBitratePreset: DownloadBitratePreset = .normal
    @AppStorage(downloadWifiOnlyStorageKey) private var downloadWifiOnly = true
    /// Raw slider value, where `0` is the "Unlimited" position past `10`. Default
    /// `3`, matching `downloadMaxConcurrentStorageKey`'s fallback, which documents
    /// why 3 rather than Unlimited.
    @AppStorage(downloadMaxConcurrentStorageKey) private var downloadMaxConcurrentRaw = 3

    /// Recomputed on every `body` evaluation: a `FileManager` directory scan plus
    /// a volume-capacity read, neither cached nor tied to `DownloadManager`. Cheap
    /// enough for an occasionally-visited settings screen to not need a dedicated
    /// `@Observable` size tracker.
    private var storageBreakdown: DeviceStorageBreakdown? {
        DeviceStorageBreakdown.current()
    }

    /// A fresh read on every access, like `storageBreakdown`, so a ladder override
    /// made on the pushed Advanced screen appears on return with no observation
    /// wiring.
    private var qualityLadder: DownloadQualityLadderStore { DownloadQualityLadderStore() }

    /// "Unlimited" at the slider's `0` position, else the plain count, mirroring
    /// `DownloadPreferencesStore.maxConcurrentDownloads`.
    private var downloadMaxConcurrentDisplayText: String {
        downloadMaxConcurrentRaw == 0 ? String(localized: "Unlimited") : "\(downloadMaxConcurrentRaw)"
    }

    /// Average runtimes for the free-space estimate below. Commonly-cited round
    /// figures rather than anything from the server, which this screen has no
    /// library loaded to average over, and spelled out in the disclaimer next to
    /// the estimate so they aren't taken as measured.
    private static let averageMovieMinutes = 114
    private static let averageEpisodeMinutes = 45

    /// How many items of `minutes` runtime fit in `freeBytes` at the selected
    /// resolution and quality: video plus audio bitrate — the ladder
    /// `DownloadTranscodeCalculator`/`JellyfinAPIClient.downloadStreamURL`
    /// transcode to — times runtime, bits to bytes. Ignores the never-upscale cap
    /// in `DownloadTranscodeCalculator.target` and assumes the selected tier is
    /// fully reached: a rough capacity estimate, not a prediction for one title.
    private func estimatedCount(minutes: Int, freeBytes: Int64) -> Int {
        let bitsPerSecond = qualityLadder.videoBitrate(resolution: downloadResolution, preset: downloadBitratePreset) + downloadBitratePreset.audioBitrate
        let bytesPerItem = Double(bitsPerSecond) / 8 * Double(minutes * 60)
        guard bytesPerItem > 0 else { return 0 }
        return Int(Double(freeBytes) / bytesPerItem)
    }

    private func freeSpaceEstimateText(freeBytes: Int64) -> String {
        let movieCount = estimatedCount(minutes: Self.averageMovieMinutes, freeBytes: freeBytes)
        let episodeCount = estimatedCount(minutes: Self.averageEpisodeMinutes, freeBytes: freeBytes)
        return String(localized: "Free space for about \(movieCount) movies or \(episodeCount) TV episodes at the current download settings.")
    }

    var body: some View {
        List {
            Section {
                Picker("Resolution", selection: $downloadResolution) {
                    ForEach(DownloadResolution.allCases) { resolution in
                        Text(resolution.pickerDisplayName).tag(resolution)
                    }
                }
                Picker("Quality", selection: $downloadBitratePreset) {
                    ForEach(DownloadBitratePreset.allCases) { preset in
                        let bitrate = qualityLadder.videoBitrate(resolution: downloadResolution, preset: preset)
                        Text(preset.displayName(bitrate: bitrate))
                            .accessibilityLabel(preset.accessibilityDisplayName(bitrate: bitrate))
                            .tag(preset)
                    }
                }
                // See `ProfileView`'s "Advanced" link: two screens share this
                // title, and only the identifier distinguishes them.
                NavigationLink("Advanced") {
                    DownloadsQualityLadderView()
                }
                .accessibilityIdentifier(A11yID.Profile.qualityLadderLink)
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Simultaneous Downloads", value: downloadMaxConcurrentDisplayText)
                    // `0...10`, with `0` doubling as "Unlimited" (see
                    // `downloadMaxConcurrentDisplayText`). A `Slider` rather than
                    // a `Stepper`, per an explicit ask, offering every integer
                    // 1-10 plus Unlimited as one control.
                    Slider(
                        value: Binding(
                            get: { Double(downloadMaxConcurrentRaw) },
                            set: { downloadMaxConcurrentRaw = Int($0.rounded()) }
                        ),
                        in: 0...10, step: 1
                    )
                    // Without these, VoiceOver reads the slider's raw `0...10`
                    // position rather than its meaning: the spoken counterpart to
                    // the "Unlimited" the `LabeledContent` shows there.
                    .accessibilityLabel(String(localized: "Simultaneous Downloads"))
                    .accessibilityValue(downloadMaxConcurrentDisplayText)
                }
                Toggle("Wi-Fi Only", isOn: $downloadWifiOnly)
            } header: {
                Text("Quality & Network")
            } footer: {
                // The simultaneous-downloads caveat was measured, not hedged: with
                // the limit set to 2, iOS ran up to 11 transfers at once as soon
                // as the app was suspended. `nsurlsessiond` owns and schedules
                // every task the app created, and an app can't hold one back once
                // it stops running. See DOWNLOADS.md's "iOS defers the next queued
                // download when the app is backgrounded".
                Text("Downloaded videos are transcoded to fit your chosen resolution and quality, and are never upscaled past the source.\n\nSimultaneous Downloads applies while Dionysus is open. Once it moves to the background, iOS schedules downloads itself and may run more at once than the limit you set.")
                    .readableSettingsFooter()
            }

            Section {
                if let storageBreakdown {
                    DeviceStorageBarView(
                        breakdown: storageBreakdown,
                        freeSpaceEstimateText: freeSpaceEstimateText(freeBytes: storageBreakdown.free)
                    )
                    .listRowSeparator(.hidden)
                } else {
                    // Falls back to the plain figure `ProfileView` showed before
                    // this screen existed, for the case where the volume's
                    // capacity keys aren't readable.
                    LabeledContent("Storage Used", value: ByteCountFormatter.string(fromByteCount: DownloadFileStore.totalSizeOnDisk(), countStyle: .file))
                }
            } header: {
                Text("Storage")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("An estimate of this app's downloaded videos, artwork, and subtitles against total device storage.")
                    if storageBreakdown != nil {
                        Text("Based on a \(Self.averageMovieMinutes) minute movie and \(Self.averageEpisodeMinutes) minute TV episode.")
                    }
                }
                .readableSettingsFooter()
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(titleDisplayMode)
    }
}

#Preview {
    NavigationStack { DownloadsSettingsView() }
}
