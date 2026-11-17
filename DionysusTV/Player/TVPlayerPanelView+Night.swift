import SwiftUI

// MARK: Night tab

extension TVPlayerPanelView {
    /// Night Mode's four rows: the switch, Night Audio with its note, then
    /// Volume Limit and Brightness, each `[0%] [−] value [+] [100%]`
    /// (Benjamin, 2026-11-16). Night Audio and the levels show greyed while
    /// Night Mode is off, and can still be set ahead (Night Mode spec,
    /// "Apple TV player"). Focus stops are `TVNightPanelRow.all`.
    var nightContent: some View {
        let settings = viewModel.nightMode.settings
        return VStack(alignment: .leading, spacing: 8) {
            switchRow(
                String(localized: "Night Mode"), isOn: settings.isOn, note: nil, greyed: false,
                index: TVPlayerInputModel.nightIndex(of: .nightMode)
            )
            .accessibilityIdentifier(A11yID.TV.Player.nightToggle)
            switchRow(
                String(localized: "Night Audio"), isOn: settings.nightAudio, note: nightAudioNote, greyed: !settings.isOn,
                index: TVPlayerInputModel.nightIndex(of: .nightAudio)
            )
            .accessibilityIdentifier(A11yID.TV.Player.nightAudio)
            levelRow(.volume, title: "Volume Limit", percent: settings.volumePercent, greyed: !settings.isOn)
            levelRow(.brightness, title: "Brightness", percent: settings.brightnessPercent, greyed: !settings.isOn)
        }
    }

    private var nightColumnWidth: CGFloat { 1100 }

    /// The fixed copy (Benjamin, 2026-11-16), or why it can't apply here (a
    /// server transcode).
    nonisolated static func nightAudioNote(_ state: NightAudioState) -> String {
        state == .unavailable
            ? String(localized: "Not available when transcoding")
            : String(localized: "Limits dynamic range. Turns off Atmos and passthrough while on.")
    }

    private var nightAudioNote: String { Self.nightAudioNote(viewModel.nightAudioState) }

    private static func percentText(_ percent: Int) -> String {
        percent.formatted(.percent)
    }

    /// A row's plate: white when the row itself has focus, as a track row
    /// is; greyed while Night Mode is off unless focus is in it, so what has
    /// focus stays readable.
    private func nightFace<Content: View>(
        focused: Bool, greyed: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 16) { content() }
            .foregroundStyle(focused ? Color.black : Color.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(width: nightColumnWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(focused ? Color.white : Color.white.opacity(0.08)))
            .opacity(greyed && !focused ? 0.45 : 1)
    }

    private func switchRow(
        _ title: String, isOn: Bool, note: String?, greyed: Bool, index: Int
    ) -> some View {
        control(.panelRow(index), modelFocused: isFocused(index)) { focused in
            nightFace(focused: focused, greyed: greyed) {
                // The note beside the name while it fits whole, else on a
                // second line in the row: never cut short.
                ViewThatFits(in: .horizontal) {
                    switchLine(title, isOn: isOn) {
                        if let note { noteText(note) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        switchLine(title, isOn: isOn) { EmptyView() }
                        if let note { noteText(note) }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        // The note joins the name, so VoiceOver reads it whole whatever its
        // hint setting.
        .accessibilityLabel(Text(verbatim: note.map { "\(title). \($0)" } ?? title))
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityAddTraits(.isButton)
    }

    private func switchLine<Note: View>(
        _ title: String, isOn: Bool, @ViewBuilder note: () -> Note
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(verbatim: title).font(.callout.weight(.semibold)).fixedSize()
            note()
            Spacer(minLength: 16)
            (isOn ? Text("On") : Text("Off")).font(.callout.weight(.semibold)).fixedSize()
        }
    }

    private func noteText(_ note: String) -> some View {
        Text(note).font(.caption).opacity(0.7).fixedSize()
    }

    // MARK: Levels

    private func index(_ level: TVNightLevel, _ control: TVNightLevelControl) -> Int {
        TVPlayerInputModel.nightIndex(of: .level(level, control))
    }

    private func valueIdentifier(_ level: TVNightLevel) -> String {
        level == .volume ? A11yID.TV.Player.nightVolume : A11yID.TV.Player.nightBrightness
    }

    /// With the remote, each control is its own focus stop, drawn from the
    /// model's focus. In the accessible transport the row is one adjustable
    /// element (swipe up and down step 5%, as the Audio tab's Offset row
    /// does), with 0% and 100% as named actions.
    @ViewBuilder
    private func levelRow(_ level: TVNightLevel, title: LocalizedStringKey, percent: Int, greyed: Bool) -> some View {
        if accessible {
            TVPlayerControlButton(action: {}) { focused in
                levelFace(level, title: title, percent: percent, greyed: greyed, rowFocused: focused, focusedControl: nil)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: Self.percentText(percent)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: send(.adjustPanelRow(index(level, .increase), .right))
                case .decrement: send(.adjustPanelRow(index(level, .decrease), .left))
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Set to 0%")) { send(.panelRow(index(level, .min))) }
            .accessibilityAction(named: Text("Set to 100%")) { send(.panelRow(index(level, .max))) }
            .accessibilityIdentifier(valueIdentifier(level))
        } else {
            let focusedControl = TVNightLevelControl.allCases.first { isFocused(index(level, $0)) }
            levelFace(level, title: title, percent: percent, greyed: greyed, rowFocused: false, focusedControl: focusedControl)
                .accessibilityElement(children: .contain)
        }
    }

    private func levelFace(
        _ level: TVNightLevel, title: LocalizedStringKey, percent: Int, greyed: Bool,
        rowFocused: Bool, focusedControl: TVNightLevelControl?
    ) -> some View {
        nightFace(focused: rowFocused, greyed: greyed && focusedControl == nil) {
            Text(title).font(.callout.weight(.semibold))
                .accessibilityHidden(true)
            Spacer()
            levelButton(.min, of: level, percent: percent, onLightRow: rowFocused, focused: focusedControl == .min)
            levelButton(.decrease, of: level, percent: percent, onLightRow: rowFocused, focused: focusedControl == .decrease)
            Text(verbatim: Self.percentText(percent))
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(minWidth: 110)
                .accessibilityElement()
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(verbatim: Self.percentText(percent)))
                .accessibilityIdentifier(valueIdentifier(level))
            levelButton(.increase, of: level, percent: percent, onLightRow: rowFocused, focused: focusedControl == .increase)
            levelButton(.max, of: level, percent: percent, onLightRow: rowFocused, focused: focusedControl == .max)
        }
    }

    /// The focused control is a white capsule with a black glyph; the rest a
    /// faint translucent capsule. One that would do nothing is dimmed, but
    /// keeps its place as a focus stop.
    private func levelButton(
        _ control: TVNightLevelControl, of level: TVNightLevel, percent: Int, onLightRow: Bool, focused: Bool
    ) -> some View {
        let inert = TVPlayerInputModel.nightControlIsInert(control, percent: percent)
        let restingFill = onLightRow ? Color.black.opacity(0.1) : Color.white.opacity(0.14)
        return Group {
            switch control {
            case .min: Text(verbatim: Self.percentText(NightModeLevel.range.lowerBound))
            case .max: Text(verbatim: Self.percentText(NightModeLevel.range.upperBound))
            case .decrease: Image(systemName: "minus")
            case .increase: Image(systemName: "plus")
            }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(focused ? Color.black : (onLightRow ? Color.black : Color.white))
        // Faint only at rest: focused, a dimmed control's glyph is solid
        // black on the white capsule, so it stays readable.
        .opacity(inert && !focused ? 0.35 : 1)
        .frame(minWidth: control == .min || control == .max ? 76 : 44, minHeight: 44)
        .padding(.horizontal, control == .min || control == .max ? 8 : 0)
        .background(Capsule().fill(focused ? Color.white : restingFill))
        .opacity(inert && !focused ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.controlLabel(control))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(A11yID.TV.Player.nightControl(level.id, control.id))
    }

    private static func controlLabel(_ control: TVNightLevelControl) -> Text {
        switch control {
        case .min: Text("Set to 0%")
        case .decrease: Text("Decrease")
        case .increase: Text("Increase")
        case .max: Text("Set to 100%")
        }
    }
}
