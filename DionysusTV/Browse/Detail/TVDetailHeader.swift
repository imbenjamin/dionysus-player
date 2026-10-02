import SwiftUI

/// The item's backdrop behind the whole page, the rail included, under the
/// prototype's two scrims: dark from the left for the text, and dark from
/// the bottom for the rails.
struct TVDetailBackdrop: View {
    let item: MediaItem
    /// Blurred and dimmed once focus is in the rails below the header
    /// (Benjamin, 2026-10-02), so their titles and captions read against it.
    var isBlurred = false
    private static let ground = Color(red: 11 / 255, green: 2 / 255, blue: 8 / 255)

    var body: some View {
        ZStack {
            Self.ground
            // No placeholder (Benjamin, 2026-10-02): until the backdrop is
            // there, and if it never arrives, the page is just its ground.
            TVHeldImage(item.backdropImageURL, url: { $0 }) { url in
                AsyncRemoteImage(url: url, retryPatience: .extended, showsPlaceholder: false)
            }
                .blur(radius: isBlurred ? 40 : 0)
                .overlay { Self.ground.opacity(isBlurred ? 0.55 : 0) }
            LinearGradient(colors: [Self.ground.opacity(0.92), Self.ground.opacity(0)], startPoint: .leading, endPoint: UnitPoint(x: 0.7, y: 0.5))
            LinearGradient(
                stops: [.init(color: Self.ground, location: 0), .init(color: Self.ground.opacity(0.75), location: 0.3), .init(color: Self.ground.opacity(0), location: 0.6)],
                startPoint: .bottom, endPoint: .top
            )
        }
        .animation(.easeInOut(duration: 0.3), value: isBlurred)
        .accessibilityHidden(true)
    }
}

/// Logo (title text until it loads, or when there is none), the metadata
/// line and the format badges: the overview and the actions are focusable,
/// so the page lays those out itself.
struct TVDetailHeader: View {
    let item: MediaItem
    var showsBadges = true
    /// Whose logo shows, when not the item's own: on a show's page, the
    /// episode's or season's the page is on.
    var logoSource: MediaItem?
    /// Whose format badges show, when not the item's own: a show has no
    /// media source, so its page shows those of the episode Play starts.
    var badgeSource: MediaItem?
    var titleIdentifier = A11yID.TV.Detail.title
    /// While the full item is still loading its badge row's space is held,
    /// so the rows above don't jump when the media source arrives: a tile
    /// hands the page a lighter copy of the item without one.
    var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            logo
                .frame(width: 640, height: 210, alignment: .bottomLeading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(titleIdentifier)
            HStack(spacing: 16) {
                ForEach(Array(TVDetailFormat.metadata(for: item).enumerated()), id: \.offset) { index, part in
                    if index > 0 { Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true) }
                    Text(verbatim: part)
                }
                if let rating = item.communityRating {
                    Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text(verbatim: "★ " + String(format: "%.1f", rating))
                        .foregroundStyle(Color.dionysusGold)
                        .accessibilityLabel(String(localized: "Rated: \(String(format: "%.1f", rating)) stars"))
                }
            }
            .font(.callout.weight(.semibold))
            let badges = (badgeSource ?? item).metadataBadges
            if showsBadges, isLoading || !badges.isEmpty {
                HStack(spacing: 12) {
                    // Holds the row's height while it's empty.
                    Text(verbatim: " ").font(.caption2.weight(.bold)).padding(.vertical, 5).accessibilityHidden(true)
                    ForEach(badges, id: \.self) { badge in
                        Text(verbatim: badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.5), lineWidth: 2))
                            .accessibilityIdentifier(A11yID.TV.Detail.badge)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var logo: some View {
        let title = Text(verbatim: item.name).font(.system(size: 76, weight: .bold)).lineLimit(2).minimumScaleFactor(0.5)
        TVHeldImage((logoSource ?? item).logoImageURL, url: { $0 }) { url in
            if let url {
                LogoImageView(url: url, fallback: title, retryPatience: .extended)
            } else {
                title
            }
        }
    }
}
