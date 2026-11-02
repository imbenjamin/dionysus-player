import SwiftUI

/// Profile → Playback → Advanced, iOS's `AdvancedPlaybackSettingsView` as
/// rows, with its footers. The two streaming settings work today; Subtitle
/// Styling and the stats button are stored now and take effect when their
/// player features arrive on the Apple TV (M4).
struct TVAdvancedPlaybackView: View {
    @AppStorage(streamDecisionModeStorageKey) private var streamDecisionMode: StreamDecisionMode = .allowTranscoding
    @AppStorage(streamingMaxBitrateStorageKey) private var streamingMaxBitrate: StreamingMaxBitrate = .unlimited
    @AppStorage(styledASSSubtitlesEnabledStorageKey) private var isStyledASSEnabled = styledASSSubtitlesEnabledDefault
    @AppStorage(showPlaybackStatsButtonEnabledStorageKey) private var showsStatsButton = showPlaybackStatsButtonEnabledDefault
    @AppStorage(readAheadBufferSecondsStorageKey) private var readAheadSeconds = ReadAheadBufferStore.defaultSeconds
    @FocusState private var focus: String?
    @State private var picker: Picker?

    private enum Picker: String, Identifiable {
        case streaming, maxBitrate, readAheadBuffer
        var id: String { rawValue }
    }

    private func onOff(_ value: Bool) -> String { value ? String(localized: "On") : String(localized: "Off") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced")
                .font(.title2.bold())
                .padding(.leading, 34)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(A11yID.TV.Profile.pageTitle)
            // The rows are one container named for the title, which VoiceOver
            // passes over as a header (M5).
            VStack(alignment: .leading, spacing: 12) { rows }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Advanced"))
                .accessibilityIdentifier(A11yID.TV.Profile.advancedRows)
        }
        .frame(width: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focus, A11yID.TV.Profile.streamingMode)
        .fullScreenCover(item: $picker) { picker in
            switch picker {
            case .streaming:
                TVSettingsPicker(title: "Streaming", selection: $streamDecisionMode, id: \.rawValue, label: \.displayName)
            case .maxBitrate:
                TVSettingsPicker(
                    title: "Max Streaming Bitrate",
                    selection: $streamingMaxBitrate,
                    id: \.rawValue,
                    label: \.displayName,
                    accessibilityLabel: \.accessibilityLabel
                )
            case .readAheadBuffer:
                TVStepperPage(
                    title: "Read-Ahead Buffer",
                    value: $readAheadSeconds,
                    range: ReadAheadBufferStore.options.first!...ReadAheadBufferStore.options.last!,
                    step: 30,
                    display: ReadAheadBufferStore.displayName(seconds:),
                    spoken: ReadAheadBufferStore.accessibilityLabel(seconds:),
                    resetTitle: "Reset to 5 min",
                    resetValue: ReadAheadBufferStore.defaultSeconds,
                    footer: Self.readAheadFooter,
                    ids: .init(
                        value: A11yID.TV.Profile.readAheadBufferValue,
                        decrease: A11yID.TV.Profile.readAheadBufferDecrease,
                        increase: A11yID.TV.Profile.readAheadBufferIncrease,
                        reset: A11yID.TV.Profile.readAheadBufferReset
                    )
                )
            }
        }
    }

    private static let transcodingFooter: LocalizedStringKey = "Allow Transcoding asks the server to decide, transcoding when necessary — including to keep the stream under the Max Streaming Bitrate cap, even for a file that could otherwise play untouched."
    private static let directPlayFooter: LocalizedStringKey = "Direct Play Always sends the original file untouched — best quality, but may fail if your device or network can't handle it."
    private static let readAheadFooter: LocalizedStringKey = "How far ahead a file playing directly is loaded. Raise it if playback stops to buffer on a slow network; it uses more of this device's storage while playing. Not used when the server transcodes."
    private static let stylingFooter: LocalizedStringKey = "Renders the fonts, colours and on-screen positioning authored into ASS and SSA subtitles. Turn this off to show them as plain text instead. Other subtitle formats are unaffected."
    private static let statsFooter: LocalizedStringKey = "Shows a button on the player screen for viewing technical playback details."

    /// Each footer is also its row's hint, since VoiceOver never reaches the
    /// footer (M5).
    @ViewBuilder
    private var rows: some View {
        TVSettingsRow(
            title: "Streaming", value: streamDecisionMode.displayName,
            hint: streamDecisionMode == .allowTranscoding ? Self.transcodingFooter : Self.directPlayFooter,
            opensPage: true, identifier: A11yID.TV.Profile.streamingMode
        ) {
            picker = .streaming
        }
        .focused($focus, equals: A11yID.TV.Profile.streamingMode)
        if streamDecisionMode == .allowTranscoding {
            TVSettingsRow(
                title: "Max Streaming Bitrate", value: streamingMaxBitrate.displayName, spokenValue: streamingMaxBitrate.accessibilityLabel,
                opensPage: true, identifier: A11yID.TV.Profile.maxBitrate
            ) {
                picker = .maxBitrate
            }
            .focused($focus, equals: A11yID.TV.Profile.maxBitrate)
            TVSettingsFooter(text: Self.transcodingFooter)
        } else {
            TVSettingsFooter(text: Self.directPlayFooter)
        }
        TVSettingsRow(
            title: "Read-Ahead Buffer", value: ReadAheadBufferStore.displayName(seconds: readAheadSeconds),
            spokenValue: ReadAheadBufferStore.accessibilityLabel(seconds: readAheadSeconds), hint: Self.readAheadFooter,
            opensPage: true, identifier: A11yID.TV.Profile.readAheadBuffer
        ) {
            picker = .readAheadBuffer
        }
        .padding(.top, 24)
        TVSettingsFooter(text: Self.readAheadFooter)
        TVSettingsRow(title: "ASS/SSA Subtitles", value: onOff(isStyledASSEnabled), hint: Self.stylingFooter, identifier: A11yID.TV.Profile.subtitleStyling) {
            isStyledASSEnabled.toggle()
        }
        .padding(.top, 24)
        TVSettingsFooter(text: Self.stylingFooter)
        TVSettingsRow(title: "Show Playback Stats Button", spokenTitle: "Show Playback Stats", value: onOff(showsStatsButton), hint: Self.statsFooter, identifier: A11yID.TV.Profile.statsButton) {
            showsStatsButton.toggle()
        }
        .padding(.top, 24)
        TVSettingsFooter(text: Self.statsFooter)
    }
}
