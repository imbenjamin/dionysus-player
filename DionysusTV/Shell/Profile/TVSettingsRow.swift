import SwiftUI

/// One focusable row of Profile (prototype `.srow`): a title on the left and
/// an optional value on the right. Select runs the action: an on/off setting
/// flips, and anything else opens a page, marked by a chevron (Benjamin,
/// 2026-10-05). A setting with more choices than on and off keeps its value
/// beside the chevron and is picked on a `TVSettingsPicker`.
struct TVSettingsRow: View {
    let title: LocalizedStringKey
    /// The title as VoiceOver reads it, where the shown one ends in
    /// "Button", which VoiceOver then said twice (M5).
    var spokenTitle: LocalizedStringKey?
    var value: String?
    /// The value as VoiceOver reads it, when the row abbreviates it ("30s").
    var spokenValue: String?
    /// The section footer's words about this row, for VoiceOver, which
    /// never reaches the footer itself (M5).
    var hint: LocalizedStringKey?
    var opensPage = false
    var role: ButtonRole?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack {
                Text(title)
                Spacer()
                if let value {
                    Text(verbatim: value).foregroundStyle(.secondary)
                }
                if opensPage {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .modifier(TVDestructiveRowLook(isDestructive: role == .destructive))
        // The title alone: the button joined it with the value, which was
        // then read again as the value (M5).
        .accessibilityLabel(Text(spokenTitle ?? title))
        .accessibilityValue(spokenValue ?? value ?? "")
        .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
        .accessibilityIdentifier(identifier)
    }
}

/// A destructive row's style, where a plain row keeps the system's.
private struct TVDestructiveRowLook: ViewModifier {
    let isDestructive: Bool

    func body(content: Content) -> some View {
        if isDestructive {
            content.buttonStyle(TVDestructiveRowStyle())
        } else {
            content
        }
    }
}

/// Sign Out's and Change Server's look: a red title on the resting glass, a
/// red platter with a white title in focus. The system's destructive role
/// draws a red title on a red platter at rest on tvOS 26 (Benjamin,
/// 2026-10-11), and taking that role only while focused showed the plain
/// grey platter for a frame as focus left the row: the role followed focus a
/// frame before the system's platter did (Benjamin, 2026-10-13). So the row
/// draws its own platter, from one focus value.
struct TVDestructiveRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    /// The system row's platter, measured on tvOS 26.5: 46pt high with the
    /// title 30pt in, and in focus 4pt wider and 3.5pt taller each way.
    static let height: CGFloat = 66
    static let titleInset: CGFloat = 30
    static let focusOutset = CGSize(width: 4, height: 3.5)

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.white : Color.red)
                .padding(.horizontal, TVDestructiveRowStyle.titleInset)
                .frame(height: TVDestructiveRowStyle.height)
                .background { platter }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }

        @ViewBuilder private var platter: some View {
            let outset = TVDestructiveRowStyle.focusOutset
            if isFocused {
                Capsule().fill(Color.red)
                    .padding(.horizontal, -outset.width)
                    .padding(.vertical, -outset.height)
            } else if reduceTransparency {
                Capsule().fill(TVOpaqueAtRestButtonStyle.restingPlatter)
            } else {
                Color.clear.glassEffect(.regular, in: .capsule)
            }
        }
    }
}

/// A section heading, as the prototype's `.shead`.
struct TVSettingsHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 24)
            .padding(.leading, 34)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The explanation under a section, in iOS's words. Hidden from VoiceOver,
/// which never reached it: its rows carry it as their hint instead (M5).
struct TVSettingsFooter: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// A section of rows under its heading: one container named for it, so
/// VoiceOver says the heading on the way in. The heading alone, a header,
/// was passed over (M5).
struct TVSettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let identifier: String
    let headingIdentifier: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSettingsHeader(title: title)
                .accessibilityIdentifier(headingIdentifier)
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }
}
