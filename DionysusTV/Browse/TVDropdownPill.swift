import SwiftUI

struct TVDropdownOption: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
}

/// A pill and the list of choices it opens: the grid's filters and its sort.
///
/// Not SwiftUI's `Menu`. On tvOS a `Menu` hands focus back to its button
/// about 1.3 seconds after a choice (measured from the focus system's own
/// updates: nothing has focus in between, and a request made sooner is
/// ignored). Here the choice closes the list and focus is on the pill in the
/// same pass (Benjamin, 2026-10-02).
///
/// The pill (`TVDropdownPill`) and its list (`TVDropdownList`) are drawn
/// apart: the page lays the list over its content, placed from the pill's
/// bounds (`TVDropdownAnchors`). Hung from the pill as an overlay, the list
/// sat outside the pill row's focus section, and Down from its first row
/// went nowhere: a focus section confines movement to its own frame.
///
/// One list is open at a time (`openPill`). Menu closes it; so does focus
/// leaving it. Focus ids are `pill.<id>` and `option.<id>.<option>`, in the
/// page's own focus state.
struct TVDropdown: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// Groups of choices, drawn with a divider between them.
    let sections: [[TVDropdownOption]]
    /// The list hangs from the pill's trailing edge, for a pill at the
    /// row's right.
    var alignsTrailing = false
    let identifier: String

    var options: [TVDropdownOption] { sections.flatMap { $0 } }
    static func pillFocus(_ id: String) -> String { "pill.\(id)" }
    var pillFocus: String { Self.pillFocus(id) }
    var optionPrefix: String { "option.\(id)." }
    func optionFocus(_ option: TVDropdownOption) -> String { optionPrefix + option.id }
}

/// Each pill's bounds, for the page to place the open list beneath it.
struct TVDropdownAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct TVDropdownPill: View {
    let dropdown: TVDropdown
    @Binding var openPill: String?
    let focus: FocusState<String?>.Binding

    private var isOpen: Bool { openPill == dropdown.id }
    /// The widest a pill's text gets before it's cut short.
    static let maxTitleWidth: CGFloat = 260

    var body: some View {
        Button(action: open) {
            // One line, cut short with an ellipsis: a chosen value can be
            // long ("20th Century Fox" wrapped to two lines; Benjamin,
            // 2026-10-03).
            Label {
                Text(verbatim: dropdown.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
                    // Its natural width up to the cap, not all the room offered.
                    .fixedSize(horizontal: true, vertical: false)
            } icon: {
                Image(systemName: dropdown.icon)
            }
        }
        .focused(focus, equals: dropdown.pillFocus)
        .accessibilityIdentifier(dropdown.identifier)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .anchorPreference(key: TVDropdownAnchors.self, value: .bounds) { [dropdown.id: $0] }
        // Focus that was in the list and has gone elsewhere (the rail, a
        // pill) closes it, as pressing away from a menu does.
        .onChange(of: focus.wrappedValue) { old, new in
            guard isOpen, old?.hasPrefix(dropdown.optionPrefix) == true, new?.hasPrefix(dropdown.optionPrefix) != true else { return }
            openPill = nil
        }
    }

    private func open() {
        guard let first = dropdown.options.first(where: \.isSelected) ?? dropdown.options.first else { return }
        openPill = dropdown.id
        // The list is built in the next pass; its row can't take focus
        // before then.
        let target = dropdown.optionFocus(first)
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(30))
                focus.wrappedValue = target
                if focus.wrappedValue == target { return }
            }
        }
    }
}

struct TVDropdownList: View {
    let dropdown: TVDropdown
    @Binding var openPill: String?
    let focus: FocusState<String?>.Binding

    static let rowWidth: CGFloat = 440
    private static let inset: CGFloat = 18
    /// The panel's whole width, for a list hung from a pill's trailing edge.
    static var width: CGFloat { rowWidth + inset * 2 }

    var body: some View {
        Group {
            // A long list (genres) scrolls inside its panel.
            if dropdown.options.count > 9 {
                ScrollView { rows.padding(.vertical, 6) }.frame(height: 640)
            } else {
                rows
            }
        }
        .frame(width: Self.rowWidth)
        .padding(Self.inset)
        .glassEffect(.regular, in: .rect(cornerRadius: 36))
        .onExitCommand(perform: close)
    }

    /// Focus goes to the pill at once, and is kept there for a moment: a
    /// choice changes what the page lists, and the page's own claim for its
    /// first item (`tvClaimsFocus`) can land in the pass after this one.
    private func close() {
        let pill = dropdown.pillFocus
        openPill = nil
        focus.wrappedValue = pill
        Task { @MainActor in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(40))
                if focus.wrappedValue != pill { focus.wrappedValue = pill }
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(dropdown.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Rectangle().fill(.white.opacity(0.18)).frame(height: 2).padding(.vertical, 10).padding(.horizontal, 14)
                }
                ForEach(section) { option in
                    Button {
                        option.action()
                        close()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark")
                                .font(.callout.weight(.bold))
                                .opacity(option.isSelected ? 1 : 0)
                                .accessibilityHidden(true)
                            Text(verbatim: option.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(TVDropdownRowStyle())
                    .focused(focus, equals: dropdown.optionFocus(option))
                    .accessibilityAddTraits(option.isSelected ? .isSelected : [])
                    .accessibilityIdentifier(A11yID.TV.Library.option(dropdown.id, option.id))
                }
            }
        }
    }
}

/// A row of the list: plain at rest, the system's white platter in focus.
private struct TVDropdownRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .padding(.horizontal, 22)
            .frame(height: 66)
            .background(isFocused ? Color.white : Color.clear, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
