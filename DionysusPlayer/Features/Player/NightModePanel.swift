import SwiftUI

/// Night Mode's panel in the iOS player, opened by the top row's moon:
/// the Night Mode switch, Night Audio with its note, Volume Limit and
/// Brightness, then a one-line summary of the schedule (Night Mode spec,
/// "iOS player").
///
/// Both levels share the Apple TV's row, `[0%] [−] value [+] [100%]`
/// (Benjamin, 2026-11-16): −/+ step 5% and repeat while held, and a button
/// that would do nothing is dimmed and disabled. The levels and Night Audio
/// show greyed while Night Mode is off and can still be set ahead. Under
/// VoiceOver each level row is one adjustable element (swipe up and down
/// 5%) with 0% and 100% as named actions, as on the Apple TV.
///
/// Hand-rolled, like the track picker, for the reasons in
/// `PlayerControlsOverlay.trackSelectionButton`'s doc comment. The schedule
/// is a summary only: it's edited in Profile.
struct NightModePanel: View {
    let viewModel: PlayerViewModel
    /// Resets `PlayerView`'s auto-hide countdown, as every control does.
    var onInteract: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.locale) private var locale

    /// The track picker's width, a little wider so a level's five controls
    /// fit beside its name on an iPhone; narrower, the name goes above them.
    private static let idealWidth: CGFloat = 340
    private static let maxWidth: CGFloat = 380

    enum Level: CaseIterable {
        case volume, brightness

        /// Fixed, unlocalized: identifiers use it.
        var id: String { self == .volume ? "volume" : "brightness" }
    }

    /// A level row's buttons, left to right.
    enum Control: CaseIterable {
        case min, decrease, increase, max

        /// Fixed, unlocalized: identifiers use it.
        var id: String {
            switch self {
            case .min: "min"
            case .decrease: "decrease"
            case .increase: "increase"
            case .max: "max"
            }
        }
    }

    // MARK: Rules

    /// Where `control` takes a level at `percent`: a 5% step, clamped, or
    /// an end.
    nonisolated static func target(of control: Control, from percent: Int) -> Int {
        switch control {
        case .min: NightModeLevel.range.lowerBound
        case .decrease: NightModeLevel.clamped(percent - NightModeLevel.step)
        case .increase: NightModeLevel.clamped(percent + NightModeLevel.step)
        case .max: NightModeLevel.range.upperBound
        }
    }

    /// − and 0% at 0%, + and 100% at 100%: they'd do nothing.
    nonisolated static func isInert(_ control: Control, percent: Int) -> Bool {
        target(of: control, from: percent) == percent
    }

    /// The fixed copy (Benjamin, 2026-11-16), or why it can't apply to this
    /// session (a server transcode). The Apple TV's tab says the same.
    nonisolated static func nightAudioNote(_ state: NightAudioState) -> String {
        state == .unavailable
            ? String(localized: "Not available when transcoding")
            : String(localized: "Limits dynamic range. Turns off Atmos and passthrough while on.")
    }

    /// "Schedule: 22:00–07:00", in the locale's 12- or 24-hour clock, or
    /// "Schedule: Off" while the schedule is off or its times are equal (a
    /// window that never opens).
    nonisolated static func scheduleSummary(_ schedule: NightModeSchedule, locale: Locale) -> String {
        guard schedule.isEnabled, !schedule.neverTriggers else { return String(localized: "Schedule: Off") }
        let window = "\(NightModeTimeFormat.text(schedule.turnOn, locale: locale))–\(NightModeTimeFormat.text(schedule.turnOff, locale: locale))"
        return String(localized: "Schedule: \(window)")
    }

    // MARK: Body

    var body: some View {
        let settings = viewModel.nightMode.settings
        // Its own height while that fits under the top row; scrolling when
        // it doesn't (a short window at a large text size). Chosen, not
        // measured: `estimatedHeight(for:)` in the track picker says why.
        ViewThatFits(in: .vertical) {
            rows(settings)
            ScrollView { rows(settings) }
        }
        .frame(idealWidth: Self.idealWidth, maxWidth: Self.maxWidth)
        .foregroundStyle(.white)
        // A dark switch, whatever the system's appearance: the panel is.
        .environment(\.colorScheme, .dark)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    private func rows(_ settings: NightModeSettings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: binding(settings.isOn) { viewModel.nightMode.setOn($0) }) {
                Text("Night Mode").font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier(A11yID.Player.nightToggle)
            divider
            Toggle(isOn: binding(settings.nightAudio) { viewModel.nightMode.setNightAudio($0) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Night Audio").font(.subheadline)
                    // Wraps rather than truncating (Benjamin, 2026-11-16).
                    Text(Self.nightAudioNote(viewModel.nightAudioState))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(secondaryOpacity))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .opacity(settings.isOn ? 1 : Self.greyedOpacity)
            .accessibilityIdentifier(A11yID.Player.nightAudio)
            divider
            levelRow(.volume, title: String(localized: "Volume Limit"), percent: settings.volumePercent, greyed: !settings.isOn)
            divider
            levelRow(.brightness, title: String(localized: "Brightness"), percent: settings.brightnessPercent, greyed: !settings.isOn)
            divider
            Text(Self.scheduleSummary(settings.schedule, locale: locale))
                .font(.footnote)
                .foregroundStyle(.white.opacity(secondaryOpacity))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(A11yID.Player.nightScheduleSummary)
        }
    }

    private func binding(_ value: Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { newValue in
            onInteract()
            set(newValue)
        })
    }

    private static let greyedOpacity = NightModeLevelRow.greyedOpacity
    private var secondaryOpacity: Double { colorSchemeContrast == .increased ? 0.85 : 0.6 }

    private var divider: some View {
        Divider().overlay(Color.white.opacity(0.15))
    }

    // MARK: Levels

    private func percent(of level: Level) -> Int {
        let settings = viewModel.nightMode.settings
        return level == .volume ? settings.volumePercent : settings.brightnessPercent
    }

    private func press(_ control: Control, on level: Level) {
        let target = Self.target(of: control, from: percent(of: level))
        guard target != percent(of: level) else { return }
        onInteract()
        switch level {
        case .volume: viewModel.nightMode.setVolumePercent(target)
        case .brightness: viewModel.nightMode.setBrightnessPercent(target)
        }
    }

    private func valueIdentifier(_ level: Level) -> String {
        level == .volume ? A11yID.Player.nightVolume : A11yID.Player.nightBrightness
    }

    /// The shared row (`NightModeLevelRow`), padded to the panel's rows.
    private func levelRow(_ level: Level, title: String, percent: Int, greyed: Bool) -> some View {
        NightModeLevelRow(
            title: title, percent: percent, greyed: greyed,
            valueIdentifier: valueIdentifier(level),
            controlIdentifier: { A11yID.Player.nightControl(level.id, $0.id) },
            onPress: { press($0, on: level) }
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
