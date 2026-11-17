import SwiftUI

/// One Night Mode level, `[0%] [−] value [+] [100%]` (Benjamin,
/// 2026-11-16): the player's Night panel (`NightModePanel`) and Profile's
/// Night Mode page (`NightModeSettingsView`) draw the same row.
///
/// −/+ step 5% and repeat while held, and a button that would do nothing is
/// dimmed and disabled. Under VoiceOver the row is one adjustable element
/// (swipe up and down 5%) with 0% and 100% as named actions, as on the Apple
/// TV. Colours come from the foreground style and colour scheme it sits in:
/// white on the panel's dark plate, the system's in a list.
struct NightModeLevelRow: View {
    let title: String
    let percent: Int
    /// Night Mode is off: the row shows greyed and can still be set ahead.
    let greyed: Bool
    /// The value's identifier (the row's, under VoiceOver).
    let valueIdentifier: String
    /// Each button's identifier.
    let controlIdentifier: (NightModePanel.Control) -> String
    /// A press that changes the level; never called for one that wouldn't.
    let onPress: (NightModePanel.Control) -> Void

    @VoiceOverEnabled private var voiceOverEnabled
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    static let greyedOpacity = 0.45

    private static func percentText(_ percent: Int) -> String {
        percent.formatted(.percent)
    }

    private func press(_ control: NightModePanel.Control) {
        guard !NightModePanel.isInert(control, percent: percent) else { return }
        onPress(control)
    }

    /// The name, then the five controls on the right: on one line while they
    /// fit, else the name above them.
    var body: some View {
        let row = ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                // As wide as the longer name, so both rows choose the same
                // layout: Brightness alone fitted on one line in portrait
                // where Volume Limit didn't.
                ZStack(alignment: .leading) {
                    Text("Volume Limit").hidden()
                    Text("Brightness").hidden()
                    Text(verbatim: title)
                }
                .font(.subheadline).lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                controls
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title).font(.subheadline)
                HStack {
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
        .opacity(greyed ? Self.greyedOpacity : 1)

        if voiceOverEnabled {
            // One element standing in for the whole row. With
            // `.accessibilityElement(children: .ignore)` the row's name text
            // stayed in the tree as a second element carrying the row's
            // identifier, label and value (measured in XCUITest).
            row
                .accessibilityRepresentation { Text(verbatim: title) }
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityValue(Text(verbatim: Self.percentText(percent)))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: press(.increase)
                    case .decrement: press(.decrease)
                    @unknown default: break
                    }
                }
                .accessibilityAction(named: Text("Set to 0%")) { press(.min) }
                .accessibilityAction(named: Text("Set to 100%")) { press(.max) }
                .accessibilityIdentifier(valueIdentifier)
        } else {
            row
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            button(.min)
            button(.decrease)
            Text(verbatim: Self.percentText(percent))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(minWidth: 46)
                // Named for its row, for Voice Control and the journeys; under
                // VoiceOver the row is the one element instead.
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityValue(Text(verbatim: Self.percentText(percent)))
                .accessibilityIdentifier(valueIdentifier)
            button(.increase)
            button(.max)
        }
    }

    /// A capsule, like the Audio Offset's − and +. Named with the level, so
    /// Voice Control can tell Volume Limit's − from Brightness's.
    private func button(_ control: NightModePanel.Control) -> some View {
        let inert = NightModePanel.isInert(control, percent: percent)
        let isEnd = control == .min || control == .max
        return Button {
            press(control)
        } label: {
            Group {
                switch control {
                case .min: Text(verbatim: Self.percentText(NightModeLevel.range.lowerBound))
                case .max: Text(verbatim: Self.percentText(NightModeLevel.range.upperBound))
                case .decrease: Image(systemName: "minus")
                case .increase: Image(systemName: "plus")
                }
            }
            .font(isEnd ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            .padding(.horizontal, isEnd ? 8 : 0)
            .frame(minWidth: 44, minHeight: 36)
            // `.primary` is white on the panel (dark) and black or white in a
            // list, so the capsule reads on either.
            .background(Capsule().fill(Color.primary.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(isEnd ? .automatic : .enabled)
        .disabled(inert)
        // The dimmed state is exempt from the contrast floor, but Increase
        // Contrast still needs dim told apart from gone.
        .opacity(inert ? (colorSchemeContrast == .increased ? 0.6 : 0.4) : 1)
        .accessibilityLabel(Self.controlLabel(control, title: title))
        .accessibilityIdentifier(controlIdentifier(control))
    }

    private static func controlLabel(_ control: NightModePanel.Control, title: String) -> Text {
        switch control {
        case .min: Text("Set \(title) to 0%")
        case .decrease: Text("Decrease \(title)")
        case .increase: Text("Increase \(title)")
        case .max: Text("Set \(title) to 100%")
        }
    }
}
