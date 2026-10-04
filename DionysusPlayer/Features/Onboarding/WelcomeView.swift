import SwiftUI

/// First-run welcome: one value screen rather than a carousel — the HIG's
/// "fast, fun, and optional" onboarding — continuing the splash's glyph and
/// background instead of cutting away from them. Shown until "Get Started"
/// is tapped once (`ServerSessionStore.hasCompletedWelcome`).
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingLayout) private var layout
    @State private var isRevealed = false

    private struct Feature: Identifiable {
        var id: String { systemImage }
        let systemImage: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private static let features = [
        Feature(
            systemImage: "sparkles.tv",
            title: "Plays it as it was made",
            detail: "Dolby Vision, HDR10 and surround sound, straight from your server."
        ),
        Feature(
            systemImage: "rectangle.stack.fill",
            title: "Your whole library, beautifully",
            detail: "Artwork-first browsing, Continue Watching, collections and playlists."
        ),
        Feature(
            systemImage: "arrow.down.to.line",
            title: "Take it with you",
            detail: "Download movies and shows to watch offline, anywhere."
        )
    ]

    var body: some View {
        OnboardingScreen {
            VStack(spacing: layout.isRegular ? 24 : 18) {
                DionysusGlassGlyph()
                    .onboardingGlyph()
                    .frame(width: layout.heroGlyph, height: layout.heroGlyph)

                VStack(spacing: 8) {
                    OnboardingTitle(wordmark: "Dionysus")
                    Text("Your Jellyfin library, in its best light.")
                        .font(layout.isRegular ? .title2 : .title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                .reveal(isRevealed, index: 0, reduceMotion: reduceMotion)
            }
        } content: {
            features
        } actions: {
            VStack(spacing: 16) {
                OnboardingPrimaryButton(title: "Get Started", isDefaultAction: true) {
                    appState.completeWelcome()
                }
                .accessibilityIdentifier(A11yID.Welcome.getStartedButton)

                VStack(spacing: 2) {
                    Text("Dionysus plays from your own Jellyfin media server.")
                        .foregroundStyle(.white.opacity(0.85))
                    Link(destination: Self.jellyfinURL) {
                        Text("What's Jellyfin?")
                            .fontWeight(.semibold)
                            .underline()
                            // A real target, not the footnote's own bounds.
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.white)
                    .hoverEffect(.highlight)
                    .accessibilityIdentifier(A11yID.Welcome.jellyfinLink)
                }
                .font(.footnote)
                .multilineTextAlignment(.center)
            }
            .reveal(isRevealed, index: Self.features.count + 1, reduceMotion: reduceMotion)
        }
        .task {
            // Lets the glyph's move from the splash land before the copy
            // arrives.
            try? await Task.sleep(for: .seconds(0.35))
            isRevealed = true
        }
    }

    private static let jellyfinURL = URL(string: "https://jellyfin.org")!

    /// Rows on a phone and in landscape's half-width pane; three columns on
    /// an iPad in portrait, falling back to rows when accessibility text
    /// sizes make the columns too tall to sit side by side.
    @ViewBuilder
    private var features: some View {
        if layout == .regular {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(Array(Self.features.enumerated()), id: \.element.id) { index, feature in
                        FeatureColumn(feature: feature)
                            .reveal(isRevealed, index: index + 1, reduceMotion: reduceMotion)
                    }
                }
                featureRows
            }
        } else {
            featureRows
        }
    }

    private var featureRows: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(Array(Self.features.enumerated()), id: \.element.id) { index, feature in
                FeatureRow(feature: feature)
                    .reveal(isRevealed, index: index + 1, reduceMotion: reduceMotion)
            }
        }
    }

    private struct FeatureRow: View {
        let feature: Feature

        var body: some View {
            HStack(spacing: 16) {
                FeatureIcon(systemImage: feature.systemImage, size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title)
                        .font(.headline)
                    Text(feature.detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private struct FeatureColumn: View {
        let feature: Feature

        var body: some View {
            VStack(spacing: 14) {
                FeatureIcon(systemImage: feature.systemImage, size: 72)
                VStack(spacing: 6) {
                    Text(feature.title)
                        .font(.title3.weight(.semibold))
                    Text(feature.detail)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 200)
            .accessibilityElement(children: .combine)
        }
    }

    private struct FeatureIcon: View {
        let systemImage: String
        let size: CGFloat

        var body: some View {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .onboardingGlass(in: Circle())
                // Decorative: the title beside it says what it is.
                .accessibilityHidden(true)
        }
    }
}

private extension View {
    /// A staggered fade-and-rise; a plain fade under Reduce Motion.
    func reveal(_ isRevealed: Bool, index: Int, reduceMotion: Bool) -> some View {
        opacity(isRevealed ? 1 : 0)
            .offset(y: isRevealed || reduceMotion ? 0 : 14)
            .animation(.smooth(duration: 0.6).delay(Double(index) * 0.09), value: isRevealed)
    }
}

#Preview {
    ZStack {
        OnboardingBackground()
        WelcomeView()
    }
    .environment(AppState())
    .environment(\.colorScheme, .dark)
    .foregroundStyle(.white)
}
