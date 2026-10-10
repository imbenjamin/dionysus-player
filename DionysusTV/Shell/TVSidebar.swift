import SwiftUI

/// The shell's sidebar, as the prototype draws it (screens 5, 6 and 6b):
/// collapsed, a glass rail of icons centred on the left edge, drawn on every
/// signed-in page; open (whenever one of its rows has focus), a 520pt glass
/// panel with labelled pill rows. Profile is pinned at the top. The rows, and
/// their order, come from `TVSidebarLayout.rows(libraries:librariesExpanded:)`.
///
/// Its focus section spans the screen's height, so Left from a page's
/// leftmost item at any height enters it; collapsed, only one row is enabled
/// (`TVShellNavigation.focusableRows`), so that's where focus lands.
struct TVSidebar: View {
    let rows: [TVSidebarLayout.Row]
    let libraries: [MediaItem]
    let profileUser: UserDto?
    let serverName: String?
    let serverURL: URL?
    /// Rows drawn with the selected look (`TVShellNavigation.isHighlighted`).
    let highlighted: Set<TVSidebarLayout.Row>
    /// Rows that can take focus; the rest are disabled.
    let focusable: Set<TVSidebarLayout.Row>
    let isExpanded: Bool
    let librariesExpanded: Bool
    var focus: FocusState<TVSidebarLayout.Row?>.Binding
    let onSelect: (TVSidebarLayout.Row) -> Void

    /// Folded libraries, listed after the Libraries row, show only in the open
    /// panel: the rail keeps the one folder icon.
    private var shownRows: [TVSidebarLayout.Row] {
        guard !isExpanded, let group = rows.firstIndex(of: .librariesGroup) else { return rows }
        return Array(rows[...group])
    }

    private var isFolded: Bool { rows.contains(.librariesGroup) }

    var body: some View {
        VStack(alignment: isExpanded ? .leading : .center, spacing: isExpanded ? 10 : 18) {
            ForEach(shownRows, id: \.self) { row in
                rowButton(row)
                if row == .search, shownRows.count > 3 {
                    divider
                }
            }
        }
        .padding(.vertical, isExpanded ? 44 : 22)
        .padding(.horizontal, isExpanded ? 34 : 16)
        .frame(width: isExpanded ? 520 : TVShellMetrics.railWidth, alignment: .leading)
        .frame(maxHeight: isExpanded ? .infinity : nil, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: isExpanded ? 48 : 52))
        .padding(TVShellMetrics.railLeading)
        .frame(maxHeight: .infinity, alignment: isExpanded ? .top : .center)
        .focusSection()
        // One named container, so VoiceOver says where focus went (M5).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sidebar"))
        // Open, VoiceOver read the dimmed page behind it (M5).
        .accessibilityAddTraits(isExpanded ? .isModal : [])
        .accessibilityIdentifier(A11yID.TV.Sidebar.container)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(isExpanded ? 0.12 : 0.18))
            .frame(width: isExpanded ? nil : 44, height: 2)
            .padding(.horizontal, isExpanded ? 30 : 0)
            .padding(.vertical, isExpanded ? 14 : 0)
            .accessibilityHidden(true)
    }

    private func rowButton(_ row: TVSidebarLayout.Row) -> some View {
        Button { onSelect(row) } label: {
            label(for: row)
        }
        .buttonStyle(TVSidebarRowStyle(
            isSelected: highlighted.contains(row),
            isExpanded: isExpanded,
            shape: row == .profile ? .profile : (isNested(row) ? .nested : .standard)
        ))
        .focused(focus, equals: row)
        .disabled(!focusable.contains(row))
        // One combined button, so `false` here hides nothing inside it.
        .accessibilityHidden(TVSidebarLayout.isHiddenFromAccessibility(row, isExpanded: isExpanded, focusable: focusable))
        .accessibilityLabel(Text(accessibilityLabel(for: row)))
        .accessibilityValue(Text(verbatim: accessibilityValue(for: row)))
        // The page on show, so VoiceOver says which is current (M5).
        .accessibilityAddTraits(highlighted.contains(row) ? .isSelected : [])
        .accessibilityIdentifier(identifier(for: row))
    }

    @ViewBuilder
    private func label(for row: TVSidebarLayout.Row) -> some View {
        switch row {
        case .profile:
            HStack(spacing: 22) {
                avatar(size: isExpanded ? 68 : 60)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: profileUser?.name ?? "")
                            .font(.system(size: 31, weight: .semibold))
                        if let serverName {
                            Text(verbatim: serverName)
                                .font(.system(size: 23, weight: .medium))
                                .opacity(0.6)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        default:
            HStack(spacing: 26) {
                Image(systemName: symbol(for: row))
                    .font(.system(size: isNested(row) ? 30 : 34, weight: .medium))
                    .frame(width: 40)
                if isExpanded {
                    Text(verbatim: title(for: row))
                        .font(.system(size: isNested(row) ? 29 : 31, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if row == .librariesGroup {
                        Image(systemName: librariesExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 24, weight: .bold))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func avatar(size: CGFloat) -> some View {
        if let profileUser {
            UserAvatar(user: profileUser, serverURL: serverURL, size: size)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: size, height: size)
        }
    }

    private func isNested(_ row: TVSidebarLayout.Row) -> Bool {
        if case .library = row { return isFolded }
        return false
    }

    private func library(_ id: String) -> MediaItem? {
        libraries.first { $0.id == id }
    }

    private func title(for row: TVSidebarLayout.Row) -> String {
        switch row {
        case .profile: profileUser?.name ?? ""
        case .home: String(localized: "Home")
        case .search: String(localized: "Search")
        case .librariesGroup: String(localized: "Libraries")
        case .library(let id): library(id)?.name ?? ""
        }
    }

    /// Profile reads as where it goes, not whose it is (Benjamin, 2026-09-30).
    private func accessibilityLabel(for row: TVSidebarLayout.Row) -> String {
        row == .profile ? String(localized: "Profile & Settings") : title(for: row)
    }

    /// The Libraries row says whether it's open; its chevron is drawn, not
    /// read (M5).
    private func accessibilityValue(for row: TVSidebarLayout.Row) -> String {
        guard row == .librariesGroup else { return "" }
        return librariesExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
    }

    private func symbol(for row: TVSidebarLayout.Row) -> String {
        switch row {
        case .profile: "person.crop.circle.fill"
        case .home: "house"
        case .search: "magnifyingglass"
        case .librariesGroup: "folder"
        case .library(let id): TVSidebarLayout.systemImage(forCollectionType: library(id)?.collectionType)
        }
    }

    private func identifier(for row: TVSidebarLayout.Row) -> String {
        switch row {
        case .profile: A11yID.TV.Sidebar.profile
        case .home: A11yID.TV.Sidebar.home
        case .search: A11yID.TV.Sidebar.search
        case .librariesGroup: A11yID.TV.Sidebar.librariesGroup
        case .library(let id): A11yID.TV.Sidebar.library(id)
        }
    }
}

/// The prototype's sidebar rows: at rest a translucent label, tinted white at
/// 14% when it's the screen on show; focused, a white pill with a dark label,
/// lifted slightly. Collapsed, each row is a 72pt circle.
struct TVSidebarRowStyle: ButtonStyle {
    enum Shape { case standard, nested, profile }

    let isSelected: Bool
    let isExpanded: Bool
    let shape: Shape

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, style: self)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let style: TVSidebarRowStyle
        @Environment(\.isFocused) private var isFocused

        private static let darkLabel = Color(red: 20 / 255, green: 8 / 255, blue: 16 / 255)

        private var height: CGFloat {
            guard style.isExpanded else { return 72 }
            switch style.shape {
            case .standard: return 84
            case .nested: return 64
            case .profile: return 108
            }
        }

        private var fill: Color {
            if isFocused { return .white }
            return style.isSelected ? .white.opacity(0.14) : .clear
        }

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Self.darkLabel : .white.opacity(style.isSelected ? 1 : 0.8))
                .padding(.leading, style.isExpanded ? (style.shape == .nested ? 60 : (style.shape == .profile ? 20 : 30)) : 0)
                .padding(.trailing, style.isExpanded ? 30 : 0)
                .frame(width: style.isExpanded ? nil : 72, height: height)
                .frame(maxWidth: style.isExpanded ? .infinity : nil, alignment: .leading)
                .background(Capsule().fill(fill))
                .scaleEffect(isFocused ? (style.isExpanded ? 1.05 : 1.12) : 1)
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.2), value: isFocused)
        }
    }
}
