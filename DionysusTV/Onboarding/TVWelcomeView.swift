import SwiftUI

/// The first-run welcome: iOS's feature lines, with Downloads (absent on
/// Apple TV) replaced by one about Apple TV users. Shown once, as on iOS
/// (`ServerSessionStore.hasCompletedWelcome`); a second Apple TV user never
/// sees it, since the server they share already counts as set up.
///
/// The prototype's "What's Jellyfin?" pill is left out: tvOS has no browser
/// to open jellyfin.org in.
struct TVWelcomeView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var getStartedFocused: Bool

    private struct Feature: Identifiable {
        let id: String
        let systemImage: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private static let features = [
        Feature(
            id: "quality", systemImage: "sparkles.tv",
            title: "Plays it as it was made",
            detail: "Dolby Vision, HDR10 and surround sound, straight from your server, with the TV switched to match every frame rate and range."
        ),
        Feature(
            id: "library", systemImage: "rectangle.stack",
            title: "Your whole library, beautifully",
            detail: "Artwork-first browsing, Continue Watching, collections and playlists."
        ),
        Feature(
            id: "profiles", systemImage: "person.2",
            title: "Everyone gets their own",
            detail: "Switch Apple TV users in Control Center and Dionysus follows, each person signed in to their own Jellyfin account."
        )
    ]

    var body: some View {
        TVBrandBackground {
            TVOnboardingPanes {
                VStack(spacing: 36) {
                    Image("DionysusGlyph")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 300, height: 300)
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 16)
                        .accessibilityHidden(true)
                    // The wordmark's face on iOS (`OnboardingTitle(wordmark:)`).
                    Text(verbatim: "Dionysus")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                        .accessibilityHidden(true)
                }
            } task: {
                VStack(alignment: .leading, spacing: 44) {
                    Text("Your Jellyfin library, in its best light.")
                        .font(.title2.bold())
                        .frame(maxWidth: 820, alignment: .leading)
                        .accessibilityIdentifier(A11yID.TV.Onboarding.welcomeTitle)
                    VStack(alignment: .leading, spacing: 34) {
                        ForEach(Self.features) { feature in
                            HStack(alignment: .top, spacing: 30) {
                                Image(systemName: feature.systemImage)
                                    .font(.system(size: 40))
                                    .foregroundStyle(Color.dionysusGold)
                                    .frame(width: 88, height: 88)
                                    .glassEffect(.regular, in: .circle)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(feature.title).font(.headline)
                                    Text(feature.detail)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: 760, alignment: .leading)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        // The width goes on the label: a tvOS button sizes its
                        // capsule to the label and centres it in any outer frame.
                        Button { appState.completeWelcome() } label: {
                            Text("Get Started").frame(width: 500)
                        }
                            .focused($getStartedFocused)
                            .accessibilityIdentifier(A11yID.TV.Onboarding.getStarted)
                        Text("Dionysus plays from your own Jellyfin media server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                }
            }
        }
        .defaultFocus($getStartedFocused, true)
    }
}
