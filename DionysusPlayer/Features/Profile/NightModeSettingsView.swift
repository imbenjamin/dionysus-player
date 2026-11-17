import SwiftUI

/// Profile → Playback → Night Mode (Night Mode spec, "Profile"): the player
/// panel's switch and levels, so it can be set up away from a film, then the
/// schedule.
///
/// The switches and levels are the panel's (`NightModeLevelRow`), in the
/// list's colours. The schedule's rules live in `NightModeController`:
/// turning it on or moving a time changes nothing until the next boundary,
/// and turning it off keeps Night Mode as it is. The pickers show times in
/// GMT, as `NightModeTimeFormat` stores them, so no time zone or
/// daylight-saving gap moves what was picked (checked in New York's zone by
/// `testNightModeScheduleTurnOnReachesThePlayerOutsideGMT`); 12- or 24-hour
/// follows the locale.
struct NightModeSettingsView: View {
    private var controller: NightModeController { NightModeController.shared }

    var body: some View {
        let settings = controller.settings
        Form {
            Section {
                Toggle("Night Mode", isOn: Binding(get: { settings.isOn }, set: { controller.setOn($0) }))
                    .accessibilityIdentifier(A11yID.Profile.nightToggle)
                Toggle(isOn: Binding(get: { settings.nightAudio }, set: { controller.setNightAudio($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Night Audio")
                        Text("Limits dynamic range. Turns off Atmos and passthrough while on.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(settings.isOn ? 1 : NightModeLevelRow.greyedOpacity)
                .accessibilityIdentifier(A11yID.Profile.nightAudio)
                levelRow(.volume, title: String(localized: "Volume Limit"), percent: settings.volumePercent, greyed: !settings.isOn)
                levelRow(.brightness, title: String(localized: "Brightness"), percent: settings.brightnessPercent, greyed: !settings.isOn)
            }

            Section {
                Toggle("Schedule", isOn: scheduleBinding(\.isEnabled))
                    .accessibilityIdentifier(A11yID.Profile.nightSchedule)
                if settings.schedule.isEnabled {
                    DatePicker("Turn On", selection: timeBinding(\.turnOn), displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier(A11yID.Profile.nightTurnOn)
                    DatePicker("Turn Off", selection: timeBinding(\.turnOff), displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier(A11yID.Profile.nightTurnOff)
                }
            } footer: {
                if settings.schedule.isEnabled && settings.schedule.neverTriggers {
                    Text("The schedule never turns Night Mode on or off while both times are the same.")
                        .readableSettingsFooter()
                        .accessibilityIdentifier(A11yID.Profile.nightSameTimesNote)
                }
            }
        }
        // The pickers' dates are times in GMT (`NightModeTimeFormat`).
        .environment(\.timeZone, NightModeTimeFormat.timeZone)
        .navigationTitle("Night Mode")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func levelRow(_ level: NightModePanel.Level, title: String, percent: Int, greyed: Bool) -> some View {
        NightModeLevelRow(
            title: title, percent: percent, greyed: greyed,
            valueIdentifier: level == .volume ? A11yID.Profile.nightVolume : A11yID.Profile.nightBrightness,
            controlIdentifier: { A11yID.Profile.nightControl(level.id, $0.id) },
            // Read live, not `percent`: a held − or + repeats from a press
            // the row captured when it was last drawn.
            onPress: { control in
                let settings = controller.settings
                let now = level == .volume ? settings.volumePercent : settings.brightnessPercent
                let target = NightModePanel.target(of: control, from: now)
                guard target != now else { return }
                switch level {
                case .volume: controller.setVolumePercent(target)
                case .brightness: controller.setBrightnessPercent(target)
                }
            }
        )
    }

    private func scheduleBinding(_ keyPath: WritableKeyPath<NightModeSchedule, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.settings.schedule[keyPath: keyPath] },
            set: { newValue in
                var schedule = controller.settings.schedule
                schedule[keyPath: keyPath] = newValue
                controller.setSchedule(schedule)
            }
        )
    }

    private func timeBinding(_ keyPath: WritableKeyPath<NightModeSchedule, TimeOfDay>) -> Binding<Date> {
        Binding(
            get: { NightModeTimeFormat.date(for: controller.settings.schedule[keyPath: keyPath]) },
            set: { newValue in
                var schedule = controller.settings.schedule
                schedule[keyPath: keyPath] = NightModeTimeFormat.time(from: newValue)
                controller.setSchedule(schedule)
            }
        )
    }
}
