import SwiftUI

/// One focusable row of Profile (prototype `.srow`): a title on the left and
/// an optional value on the right. Select runs the action: an on/off setting
/// flips, and anything else opens a page, marked by a chevron (Benjamin,
/// 2026-10-05). A setting with more choices than on and off keeps its value
/// beside the chevron and is picked on a `TVSettingsPicker`.
struct TVSettingsRow: View {
    let title: LocalizedStringKey
    var value: String?
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
        .accessibilityValue(value ?? "")
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

/// The explanation under a section, in iOS's words.
struct TVSettingsFooter: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
