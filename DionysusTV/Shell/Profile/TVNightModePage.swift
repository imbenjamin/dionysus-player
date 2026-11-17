import SwiftUI

/// Profile → Playback → Night Mode (Night Mode spec, "Profile"), a cover like
/// Advanced: the player's Night tab as settings rows, so it can be set up
/// away from a film, then the schedule.
///
/// - Night Mode and Night Audio are on/off rows; Night Audio's note sits
///   under it, as the tab's does when it doesn't fit beside the name.
/// - Volume Limit and Brightness are the tab's `[0%] [−] value [+] [100%]`
///   (Benjamin, 2026-11-16).
/// - Schedule, then while it's on Turn On and Turn Off, each `[−] 22:00 [+]`
///   in the same row (Benjamin, 2026-11-16: tvOS has no `DatePicker`): 15
///   minutes a press, wrapping past midnight (`NightModeTimeStep`), in the
///   locale's 12- or 24-hour clock.
///
/// Every control is a focus stop: Left/Right move along a row, Up/Down keep
/// the column, Select presses, and holding Select on − or + repeats every
/// 0.1 s after 0.4 s, as `TVStepperPage` does (`TVNightStepperRow`). Under
/// VoiceOver each level and time is one adjustable element.
///
/// The schedule's rules are `NightModeController.setSchedule`'s: turning it
/// on or moving a time changes nothing until the next boundary.
struct TVNightModePage: View {
    @Environment(\.locale) private var locale
    @FocusState private var focus: String?

    private var controller: NightModeController { NightModeController.shared }

    private func onOff(_ value: Bool) -> String { value ? String(localized: "On") : String(localized: "Off") }

    var body: some View {
        let settings = controller.settings
        VStack(alignment: .leading, spacing: 12) {
            Text("Night Mode")
                .font(.title2.bold())
                .padding(.leading, 34)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(A11yID.TV.Profile.pageTitle)
            // The rows are one container named for the title, which VoiceOver
            // passes over as a header (M5).
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { rows(settings) }
                    .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Night Mode"))
            .accessibilityIdentifier(A11yID.TV.Profile.nightRows)
        }
        .frame(width: 1100)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focus, A11yID.TV.Profile.nightToggle)
    }

    @ViewBuilder
    private func rows(_ settings: NightModeSettings) -> some View {
        TVSettingsRow(title: "Night Mode", value: onOff(settings.isOn), identifier: A11yID.TV.Profile.nightToggle) {
            controller.setOn(!settings.isOn)
        }
        .focused($focus, equals: A11yID.TV.Profile.nightToggle)
        TVSettingsRow(
            title: "Night Audio", value: onOff(settings.nightAudio),
            hint: "Limits dynamic range. Turns off Atmos and passthrough while on.",
            identifier: A11yID.TV.Profile.nightAudio
        ) {
            controller.setNightAudio(!settings.nightAudio)
        }
        .focused($focus, equals: A11yID.TV.Profile.nightAudio)
        .opacity(settings.isOn || focus == A11yID.TV.Profile.nightAudio ? 1 : TVNightStepperRow.greyedOpacity)
        TVSettingsFooter(text: "Limits dynamic range. Turns off Atmos and passthrough while on.")
        TVNightLevelRow(
            level: .volume, title: "Volume Limit", percent: settings.volumePercent, greyed: !settings.isOn,
            current: { controller.settings.volumePercent }, set: { controller.setVolumePercent($0) }
        )
        .padding(.top, 12)
        TVNightLevelRow(
            level: .brightness, title: "Brightness", percent: settings.brightnessPercent, greyed: !settings.isOn,
            current: { controller.settings.brightnessPercent }, set: { controller.setBrightnessPercent($0) }
        )

        TVSettingsRow(title: "Schedule", value: onOff(settings.schedule.isEnabled), identifier: A11yID.TV.Profile.nightSchedule) {
            var schedule = settings.schedule
            schedule.isEnabled.toggle()
            controller.setSchedule(schedule)
        }
        .padding(.top, 36)
        if settings.schedule.isEnabled {
            timeRows(settings.schedule)
        }
    }

    @ViewBuilder
    private func timeRows(_ schedule: NightModeSchedule) -> some View {
        timeRow(title: "Turn On", \.turnOn, schedule: schedule, id: "turnOn", valueIdentifier: A11yID.TV.Profile.nightTurnOn)
        timeRow(title: "Turn Off", \.turnOff, schedule: schedule, id: "turnOff", valueIdentifier: A11yID.TV.Profile.nightTurnOff)
        if schedule.neverTriggers {
            // Plain text, not a `TVSettingsFooter`, which is hidden from
            // VoiceOver: nothing else says why the schedule does nothing.
            Text("The schedule never turns Night Mode on or off while both times are the same.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(A11yID.TV.Profile.nightSameTimesNote)
        }
    }

    /// `[−] 22:00 [+]`: never inert, since a time wraps past midnight.
    private func timeRow(
        title: LocalizedStringKey, _ keyPath: WritableKeyPath<NightModeSchedule, TimeOfDay>,
        schedule: NightModeSchedule, id: String, valueIdentifier: String
    ) -> some View {
        let time = schedule[keyPath: keyPath]
        let text = NightModeTimeFormat.text(time, locale: locale)
        let step: @MainActor (Bool) -> Void = { forward in
            var schedule = controller.settings.schedule
            schedule[keyPath: keyPath] = NightModeTimeStep.step(schedule[keyPath: keyPath], forward: forward)
            controller.setSchedule(schedule)
        }
        return TVNightStepperRow(
            title: title, value: text, valueMinWidth: 150, valueIdentifier: valueIdentifier, greyed: false,
            leading: [
                .init(id: A11yID.TV.Profile.nightTimeControl(id, "decrease"), glyph: .symbol("minus"),
                      label: Text("Earlier"), repeats: true) { step(false) },
            ],
            trailing: [
                .init(id: A11yID.TV.Profile.nightTimeControl(id, "increase"), glyph: .symbol("plus"),
                      label: Text("Later"), repeats: true) { step(true) },
            ],
            increment: { step(true) }, decrement: { step(false) }
        )
    }
}

/// One level on `TVNightModePage`, as the player's Night tab draws it:
/// the name, then `[0%] [−] value [+] [100%]`.
struct TVNightLevelRow: View {
    let level: TVNightLevel
    let title: LocalizedStringKey
    let percent: Int
    let greyed: Bool
    /// The level as stored now: a held step runs from a task started with
    /// the row's first value, so it reads the live one each time.
    let current: @MainActor () -> Int
    let set: @MainActor (Int) -> Void

    /// Where `control` takes a level at `percent`, as the player's tab.
    static func target(of control: TVNightLevelControl, from percent: Int) -> Int {
        switch control {
        case .min: NightModeLevel.range.lowerBound
        case .decrease: NightModeLevel.clamped(percent - NightModeLevel.step)
        case .increase: NightModeLevel.clamped(percent + NightModeLevel.step)
        case .max: NightModeLevel.range.upperBound
        }
    }

    private static func percentText(_ percent: Int) -> String {
        percent.formatted(.percent)
    }

    private func press(_ control: TVNightLevelControl) {
        let now = current()
        let target = Self.target(of: control, from: now)
        guard target != now else { return }
        set(target)
    }

    private func control(_ control: TVNightLevelControl) -> TVNightStepperRow.Control {
        let glyph: TVNightStepperRow.Control.Glyph = switch control {
        case .min: .text(Self.percentText(NightModeLevel.range.lowerBound))
        case .max: .text(Self.percentText(NightModeLevel.range.upperBound))
        case .decrease: .symbol("minus")
        case .increase: .symbol("plus")
        }
        let label: Text = switch control {
        case .min: Text("Set to 0%")
        case .decrease: Text("Decrease")
        case .increase: Text("Increase")
        case .max: Text("Set to 100%")
        }
        return .init(
            id: A11yID.TV.Profile.nightControl(level.id, control.id), glyph: glyph, label: label,
            repeats: control == .decrease || control == .increase,
            inert: TVPlayerInputModel.nightControlIsInert(control, percent: percent)
        ) { press(control) }
    }

    var body: some View {
        TVNightStepperRow(
            title: title, value: Self.percentText(percent), valueMinWidth: 110,
            valueIdentifier: level == .volume ? A11yID.TV.Profile.nightVolume : A11yID.TV.Profile.nightBrightness,
            greyed: greyed,
            leading: [control(.min), control(.decrease)],
            trailing: [control(.increase), control(.max)],
            increment: { press(.increase) }, decrement: { press(.decrease) },
            setToMin: { press(.min) }, setToMax: { press(.max) }
        )
    }
}

/// A Night Mode row on the Apple TV's Profile page: the name, then buttons
/// either side of a value, right-aligned, as the player's Night tab draws its
/// levels. Each button is a focus stop (a white capsule with a black glyph
/// when focused; dimmed at rest when it would do nothing, but still a stop,
/// so focus never jumps). Holding Select on a repeating one steps every
/// 0.1 s after 0.4 s, and the release adds no step of its own, as
/// `TVStepperPage`. Under VoiceOver the row is one adjustable element.
struct TVNightStepperRow: View {
    struct Control {
        enum Glyph {
            case text(String)
            case symbol(String)
        }

        /// The button's accessibility identifier, also its focus key.
        let id: String
        let glyph: Glyph
        let label: Text
        var repeats = false
        var inert = false
        let press: @MainActor () -> Void

        var isText: Bool {
            if case .text = glyph { return true }
            return false
        }
    }

    let title: LocalizedStringKey
    let value: String
    let valueMinWidth: CGFloat
    let valueIdentifier: String
    /// Night Mode is off: drawn faint until focus is in the row.
    let greyed: Bool
    let leading: [Control]
    let trailing: [Control]
    let increment: @MainActor () -> Void
    let decrement: @MainActor () -> Void
    /// A level's ends, as "Set to 0%" and "Set to 100%" actions under
    /// VoiceOver; a time has none.
    var setToMin: (@MainActor () -> Void)?
    var setToMax: (@MainActor () -> Void)?

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @FocusState private var focused: String?
    @State private var repeatTask: Task<Void, Never>?
    /// The hold stepped at least once, so the button's own action, which
    /// fires on release, mustn't step again.
    @State private var holdRepeated = false

    static let greyedOpacity = 0.45

    var body: some View {
        if voiceOverEnabled {
            // One adjustable element, as the tab's accessible transport.
            accessibleRow
                .accessibilityActions {
                    if let setToMin { Button("Set to 0%") { setToMin() } }
                    if let setToMax { Button("Set to 100%") { setToMax() } }
                }
        } else {
            face
                .focusSection()
                .accessibilityElement(children: .contain)
                .onDisappear { stopRepeating() }
        }
    }

    private var accessibleRow: some View {
        Button {} label: { face }
            .buttonStyle(TVNightRowButtonStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: value))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: increment()
                case .decrement: decrement()
                @unknown default: break
                }
            }
            .accessibilityIdentifier(valueIdentifier)
    }

    private var face: some View {
        HStack(spacing: 16) {
            Text(title)
                .accessibilityHidden(true)
            Spacer()
            ForEach(leading, id: \.id) { button($0) }
            Text(verbatim: value)
                .monospacedDigit()
                .fontWeight(.semibold)
                .frame(minWidth: valueMinWidth)
                .accessibilityElement()
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(verbatim: value))
                .accessibilityIdentifier(valueIdentifier)
            ForEach(trailing, id: \.id) { button($0) }
        }
        .padding(.leading, 30)
        .padding(.trailing, 12)
        .frame(height: 76)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .opacity(greyed && focused == nil ? Self.greyedOpacity : 1)
    }

    private func button(_ control: Control) -> some View {
        let isText = control.isText
        return Button {
            if holdRepeated {
                holdRepeated = false
            } else if !control.inert {
                control.press()
            }
        } label: {
            Group {
                switch control.glyph {
                case .text(let text): Text(verbatim: text)
                case .symbol(let name): Image(systemName: name)
                }
            }
            .font(.caption.weight(.bold))
            .frame(minWidth: isText ? 76 : 44, minHeight: 44)
            .padding(.horizontal, isText ? 8 : 0)
        }
        .buttonStyle(TVNightControlStyle(inert: control.inert))
        .onLongPressGesture(minimumDuration: 0.4, perform: {}, onPressingChanged: { pressing in
            guard control.repeats else { return }
            pressing ? startRepeating(control) : stopRepeating()
        })
        .focused($focused, equals: control.id)
        .accessibilityLabel(control.label)
        .accessibilityIdentifier(control.id)
    }

    private func startRepeating(_ control: Control) {
        repeatTask?.cancel()
        holdRepeated = false
        repeatTask = Task {
            try? await Task.sleep(for: TVStepperPage.repeatDelay)
            while !Task.isCancelled {
                holdRepeated = true
                // Each press reads the live value and does nothing at an
                // end, so a hold stops stepping there by itself.
                control.press()
                try? await Task.sleep(for: TVStepperPage.repeatInterval)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

/// A row control's capsule: white with a black glyph when focused, a faint
/// translucent one at rest; one that would do nothing is dimmed at rest but
/// stays a focus stop, so focus never jumps as a level reaches its end.
private struct TVNightControlStyle: ButtonStyle {
    let inert: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, inert: inert)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let inert: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .opacity(inert && !isFocused ? 0.35 : 1)
                .background(Capsule().fill(isFocused ? Color.white : Color.white.opacity(0.14)))
                .opacity(inert && !isFocused ? 0.6 : 1)
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.02 : 1.08) : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }
    }
}

/// The accessible row: the face as it is, outlined in focus.
private struct TVNightRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .overlay(Capsule().strokeBorder(Color.white, lineWidth: isFocused ? 4 : 0))
                .scaleEffect(isFocused ? 1.02 : 1)
        }
    }
}
