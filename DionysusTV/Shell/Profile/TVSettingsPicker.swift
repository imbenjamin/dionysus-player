import SwiftUI

/// A setting with more than on and off (Next Episode Countdown, Streaming,
/// Max Streaming Bitrate) chosen from a page listing every option, as the
/// Apple TV's own Settings does, rather than cycled by Select on its row
/// (Benjamin, 2026-10-05). The current choice is ticked and takes focus;
/// Select picks and closes, Menu closes without changing anything.
///
/// A cover of its own, not a SwiftUI `Menu`: a tvOS `Menu` hands focus back
/// to its button about 1.3 seconds after a choice (see `TVDropdownPill`).
struct TVSettingsPicker<Option: Hashable>: View {
    let title: LocalizedStringKey
    let options: [Option]
    @Binding var selection: Option
    /// Each option's identifier suffix (`A11yID.TV.Profile.option`).
    let id: (Option) -> String
    let label: (Option) -> String
    /// What VoiceOver reads, when the label is an abbreviation ("30s").
    var accessibilityLabel: ((Option) -> String)?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .padding(.leading, 34)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                    dismiss()
                } label: {
                    HStack {
                        Text(verbatim: label(option))
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .focused($focused, equals: id(option))
                .accessibilityLabel(Text(verbatim: accessibilityLabel?(option) ?? label(option)))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier(A11yID.TV.Profile.option(id(option)))
            }
        }
        .frame(width: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focused, id(selection))
    }
}

extension TVSettingsPicker where Option: CaseIterable, Option.AllCases == [Option] {
    init(
        title: LocalizedStringKey,
        selection: Binding<Option>,
        id: @escaping (Option) -> String,
        label: @escaping (Option) -> String,
        accessibilityLabel: ((Option) -> String)? = nil
    ) {
        self.init(title: title, options: Option.allCases, selection: selection, id: id, label: label, accessibilityLabel: accessibilityLabel)
    }
}
