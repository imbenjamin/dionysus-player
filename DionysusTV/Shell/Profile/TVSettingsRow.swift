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
        // The title alone: the button joined it with the value, which was
        // then read again as the value (M5).
        .accessibilityLabel(Text(spokenTitle ?? title))
        .accessibilityValue(spokenValue ?? value ?? "")
        .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
        .accessibilityIdentifier(identifier)
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
