import SwiftUI

/// The "Cast & Crew" tab's content: a grid of circular headshots, name, and
/// role (character name for actors, job title for crew) — see
/// `MediaItem.cast`.
struct CastCrewGridView: View {
    let cast: [CastMember]

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 16, alignment: .top)]

    var body: some View {
        if cast.isEmpty {
            Text("No cast or crew information available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(cast) { person in
                    CastMemberCard(person: person)
                }
            }
        }
    }
}

private struct CastMemberCard: View {
    let person: CastMember

    /// "Tom Holland, Ian Lightfoot (voice)" — a single grouped read rather
    /// than VoiceOver stopping on the headshot, name, and role as three
    /// separate elements (the headshot itself carries no information of
    /// its own beyond what the name/role already say, and the default
    /// per-`Text` splitting made a full card three swipes instead of one).
    private var accessibilityText: String {
        guard let role = person.role else { return person.name }
        return "\(person.name), \(role)"
    }

    var body: some View {
        VStack(spacing: 6) {
            // `MediaPlaceholderBox`'s "person.fill" glyph (via
            // `AsyncRemoteImage`) now covers both "no image tag at all" and
            // "fetch failed" with one code path — previously only the
            // former had a representative glyph; a failed fetch fell back
            // to a plain gray box.
            AsyncRemoteImage(url: person.imageURL, placeholderSystemImage: "person.fill", glyphSize: 20)
                .frame(width: 84, height: 84)
                .clipShape(Circle())

            Text(person.name)
                .font(.caption.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if let role = person.role {
                Text(role)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
