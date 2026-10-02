import SwiftUI

/// Cast & Crew on a detail page. Focusable and walkable, though Select does
/// nothing yet: there is no person page (Benjamin, 2026-10-02). Focus ids
/// are `cast.<id>`.
struct TVCastRail: View {
    let cast: [CastMember]
    let focus: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast & Crew").font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 56) {
                    ForEach(cast) { member in
                        Button {} label: {
                            VStack(spacing: 14) {
                                AsyncRemoteImage(url: member.imageURL, placeholderSystemImage: "person.fill")
                                    .frame(width: 180, height: 180)
                                    .clipShape(Circle())
                                    .accessibilityHidden(true)
                                Text(verbatim: member.name).font(.caption.weight(.semibold)).lineLimit(1)
                                if let role = member.role {
                                    Text(verbatim: role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: 180)
                        }
                        .buttonStyle(TVCastTileStyle())
                        .focused(focus, equals: "cast.\(member.id)")
                        .accessibilityElement(children: .combine)
                        .accessibilityRemoveTraits(.isButton)
                        .accessibilityIdentifier(A11yID.TV.Detail.cast(member.id))
                    }
                }
                .padding(.vertical, 30)
                .padding(.trailing, 80)
            }
            .scrollClipDisabled()
            .focusSection()
        }
    }
}

/// A person in Cast & Crew: the portrait lifts and gains a shadow on focus.
private struct TVCastTileStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.12 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 20, y: 12)
            .opacity(isFocused ? 1 : 0.85)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
