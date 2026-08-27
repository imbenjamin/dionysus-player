import SwiftUI

/// Downloads settings, split out from `ProfileView` into its own pushed
/// screen once the section grew a storage graph alongside its existing
/// quality/network pickers — matches iOS Settings' own pattern of a summary
/// row on the parent screen pushing to a dedicated sub-screen.
///
/// Reached only from `ProfileView`, via a plain `NavigationLink(destination:)`
/// rather than a new `AppRoute` case — `AppRoute` is for destinations
/// pushed from more than one feature's navigation stack, and this is only
/// ever reached from within `ProfileView`'s own.
struct DownloadsSettingsView: View {
    /// Default must stay in lockstep with `DownloadPreferencesStore.resolution`'s
    /// own fallback — see that type's doc comment.
    @AppStorage(downloadResolutionStorageKey) private var downloadResolution: DownloadResolution = .deviceClassDefault
    @AppStorage(downloadBitratePresetStorageKey) private var downloadBitratePreset: DownloadBitratePreset = .normal
    @AppStorage(downloadWifiOnlyStorageKey) private var downloadWifiOnly = true
    /// Raw slider value — `0` is its own "Unlimited" position, past `10`.
    /// Default `5`, matching `downloadMaxConcurrentStorageKey`'s own
    /// fallback (see its doc comment for why 5, not Unlimited).
    @AppStorage(downloadMaxConcurrentStorageKey) private var downloadMaxConcurrentRaw = 5

    /// Recomputed on every `body` evaluation — a plain `FileManager`
    /// directory scan plus a volume-capacity read, not cached or reactively
    /// tied to `DownloadManager`. Fine for a settings screen visited
    /// occasionally, and simpler than wiring a dedicated `@Observable` size
    /// tracker just for this one screen.
    private var storageBreakdown: DeviceStorageBreakdown? {
        DeviceStorageBreakdown.current()
    }

    /// "Unlimited" at the slider's `0` position, else the plain count —
    /// mirrors `DownloadPreferencesStore.maxConcurrentDownloads`'s own
    /// `0`-means-unlimited mapping.
    private var downloadMaxConcurrentDisplayText: String {
        downloadMaxConcurrentRaw == 0 ? String(localized: "Unlimited") : "\(downloadMaxConcurrentRaw)"
    }

    /// Average runtimes used for the free-space estimate below — not
    /// sourced from the server (this screen has no library loaded to
    /// average over), just commonly-cited round figures, spelled out in the
    /// disclaimer text next to the estimate so they're never taken as
    /// measured fact.
    private static let averageMovieMinutes = 114
    private static let averageEpisodeMinutes = 45

    /// How many movies/episodes of `minutes` runtime would fit in
    /// `freeBytes` at the currently-selected resolution/quality — video +
    /// audio bitrate (the same ladder `DownloadTranscodeCalculator`/
    /// `JellyfinAPIClient.downloadStreamURL` actually transcode to) times
    /// runtime, converted from bits to bytes. Deliberately doesn't account
    /// for the "never upscale past the source" cap (`DownloadTranscodeCalculator
    /// .target`) — this is a rough capacity estimate, not a prediction for
    /// any specific title, so it assumes the selected tier is fully reached.
    private func estimatedCount(minutes: Int, freeBytes: Int64) -> Int {
        let bitsPerSecond = downloadResolution.videoBitrate(preset: downloadBitratePreset) + downloadBitratePreset.audioBitrate
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
                        Text(preset.displayName(in: downloadResolution))
                            .accessibilityLabel(preset.accessibilityDisplayName(in: downloadResolution))
                            .tag(preset)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Simultaneous Downloads", value: downloadMaxConcurrentDisplayText)
                    // `0...10`, `0` doubling as "Unlimited" (see
                    // `downloadMaxConcurrentDisplayText`) — a `Slider`
                    // rather than a `Stepper`/segmented control per an
                    // explicit ask for this specific shape, offering every
                    // integer 1-10 plus Unlimited as one continuous control.
                    Slider(
                        value: Binding(
                            get: { Double(downloadMaxConcurrentRaw) },
                            set: { downloadMaxConcurrentRaw = Int($0.rounded()) }
                        ),
                        in: 0...10, step: 1
                    )
                    // Without these, VoiceOver reads the slider's own raw
                    // `0...10` position ("0") rather than what that
                    // position actually means — the `LabeledContent` above
                    // already shows "Unlimited" visually at that same
                    // position, this is its spoken counterpart.
                    .accessibilityLabel(String(localized: "Simultaneous Downloads"))
                    .accessibilityValue(downloadMaxConcurrentDisplayText)
                }
                Toggle("Wi-Fi Only", isOn: $downloadWifiOnly)
            } header: {
                Text("Quality & Network")
            } footer: {
                Text("Downloaded videos are transcoded to fit your chosen resolution and quality, and are never upscaled past the source.")
            }

            Section {
                if let storageBreakdown {
                    DeviceStorageBarView(
                        breakdown: storageBreakdown,
                        freeSpaceEstimateText: freeSpaceEstimateText(freeBytes: storageBreakdown.free)
                    )
                    .listRowSeparator(.hidden)
                } else {
                    // Falls back to the same plain figure `ProfileView`
                    // showed before this screen existed, for the (not
                    // expected on a real device) case where the volume's
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
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { DownloadsSettingsView() }
}
