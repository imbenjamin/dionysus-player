import SwiftUI

/// A user's Jellyfin profile picture, over their initial on a colour derived
/// from their id — which is also what shows while the picture loads, or for a
/// user who never set one. The picture needs no sign-in to fetch.
struct UserAvatar: View {
    let user: UserDto
    let serverURL: URL?
    var size: CGFloat = 84

    @State private var image: UIImage?

    private var imageURL: URL? { Self.imageURL(for: user, serverURL: serverURL, size: size) }

    /// The profile picture's URL, or `nil` when the user never set one — then
    /// only the monogram shows and nothing is fetched. Sized for 3× displays.
    static func imageURL(for user: UserDto, serverURL: URL?, size: CGFloat) -> URL? {
        guard let serverURL, let tag = user.primaryImageTag else { return nil }
        return ImageURLBuilder(baseURL: serverURL, accessToken: nil)
            .userImageURL(userID: user.id, tag: tag, maxWidth: Int(size * 3))
    }

    /// A stable hue per user, so the same person is the same colour every time.
    private var hue: Double {
        let sum = user.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Double(sum % 360) / 360
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.95),
                        Color(hue: hue, saturation: 0.75, brightness: 0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                // A person's initial, not translated.
                Text(verbatim: user.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                        .transition(.opacity)
                }
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: imageURL) {
                guard let imageURL, let loaded = try? await RemoteImageLoader.shared.image(for: imageURL) else { return }
                withAnimation(.easeInOut(duration: 0.3)) { image = loaded }
            }
    }
}
