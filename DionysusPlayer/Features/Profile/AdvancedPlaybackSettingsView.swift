import SwiftUI

/// Advanced/technical playback settings, split out from `ProfileView`'s
/// "Playback" section — same reasoning as `DownloadsSettingsView`'s own doc
/// comment: keeps the main Playback section scoped to everyday settings
/// (Next Episode Countdown) while the more technical streaming controls and
/// diagnostics live behind their own pushed screen, matching iOS Settings'
/// own "General" vs "Advanced" pattern.
///
/// Reached only from `ProfileView`, via a plain `NavigationLink(destination:)`
/// rather than a new `AppRoute` case — `AppRoute` is for destinations pushed
/// from more than one feature's navigation stack, and this is only ever
/// reached from within `ProfileView`'s own.
struct AdvancedPlaybackSettingsView: View {
    /// Default `.allowTranscoding` — matches `StreamPreferenceStore
    /// .decisionMode`'s own fallback for the same "both sides declare the
    /// same default" reason as `ProfileView`'s other `@AppStorage`
    /// properties document.
    @AppStorage(streamDecisionModeStorageKey) private var streamDecisionMode: StreamDecisionMode = .allowTranscoding
    /// Default `.unlimited` — matches `StreamPreferenceStore
    /// .streamingMaxBitrate`'s own fallback, same reasoning.
    @AppStorage(streamingMaxBitrateStorageKey) private var streamingMaxBitrate: StreamingMaxBitrate = .unlimited
    /// Default must stay in lockstep with `PlayerControlsOverlay`'s own
    /// `@AppStorage` read of this same key — see
    /// `showPlaybackStatsButtonEnabledDefault`'s doc comment
    /// (`PlaybackStatsOverlay.swift`) for why the default itself differs
    /// between debug/dev and release builds.
    @AppStorage(showPlaybackStatsButtonEnabledStorageKey) private var showPlaybackStatsButtonEnabled = showPlaybackStatsButtonEnabledDefault

    var body: some View {
        List {
            // No header of its own — reads as a continuation of the
            // implicit "Streaming" grouping this section represents, same
            // "footer scoped to just the control(s) it explains" reasoning
            // as `ProfileView`'s own sections document.
            Section {
                Picker("Streaming", selection: $streamDecisionMode) {
                    ForEach(StreamDecisionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if streamDecisionMode == .allowTranscoding {
                    Picker("Max Streaming Bitrate", selection: $streamingMaxBitrate) {
                        ForEach(StreamingMaxBitrate.allCases) { tier in
                            Text(tier.displayName)
                                .accessibilityLabel(tier.accessibilityLabel)
                                .tag(tier)
                        }
                    }
                }
            } footer: {
                // Switches with the picker above rather than trying to
                // explain both modes unconditionally — only ever one is
                // relevant to what's currently selected.
                Group {
                    if streamDecisionMode == .allowTranscoding {
                        Text("Allow Transcoding asks the server to decide, transcoding when necessary — including to keep the stream under the Max Streaming Bitrate cap, even for a file that could otherwise play untouched.")
                    } else {
                        Text("Direct Play Always sends the original file untouched — best quality, but may fail if your device or network can't handle it.")
                    }
                }
                .readableSettingsFooter()
            }

            Section {
                Toggle("Show Playback Stats Button", isOn: $showPlaybackStatsButtonEnabled)
            } footer: {
                Text("Shows a button on the player screen for viewing technical playback details.")
                    .readableSettingsFooter()
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { AdvancedPlaybackSettingsView() }
}
