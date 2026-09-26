import SwiftUI

/// Everything before the main app, as one continuous scene: the splash while
/// the session restores, then — for someone not signed in — welcome, server
/// setup and sign-in.
///
/// Owns what those screens share, so none of it cuts between them:
/// - the brand background (`OnboardingBackground`), including the server's own
///   login artwork once the sign-in screen knows it (`OnboardingBackdropKey`);
/// - the glyph's matched-geometry namespace, so it moves between screens;
/// - the always-dark appearance, scoped here rather than forced on the window;
/// - the composition (`OnboardingLayout`), measured once for all of them;
/// - the portrait lock on a phone-sized screen.
struct OnboardingFlowView: View {
    enum Stage: Equatable {
        case splash
        case welcome
        case serverSetup
        case login
    }

    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Namespace private var glyphNamespace
    @State private var windowSize: CGSize = .zero
    @State private var backdropURL: URL?

    private var stage: Stage {
        if appState.isRestoringSession { return .splash }
        switch appState.phase {
        case .serverSetup:
            return appState.sessionStore.hasCompletedWelcome ? .serverSetup : .welcome
        case .login:
            return .login
        case .main:
            // Only for the instant before `RootView` swaps this view out.
            return .splash
        }
    }

    private var layout: OnboardingLayout {
        OnboardingLayout.resolve(windowSize: windowSize, horizontalSizeClass: horizontalSizeClass)
    }

    var body: some View {
        ZStack {
            OnboardingBackground(backdropURL: stage == .login ? backdropURL : nil)

            Group {
                switch stage {
                case .splash:
                    SplashView()
                case .welcome:
                    WelcomeView()
                case .serverSetup:
                    ServerSetupView()
                case .login:
                    LoginView()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .animation(.smooth(duration: 0.6), value: stage)
        .animation(.smooth, value: layout)
        .onPreferenceChange(OnboardingBackdropKey.self) { backdropURL = $0 }
        // The whole window, safe areas included — see
        // `OnboardingLayout.resolve`.
        .onGeometryChange(for: CGSize.self) { proxy in
            let insets = proxy.safeAreaInsets
            return CGSize(
                width: proxy.size.width + insets.leading + insets.trailing,
                height: proxy.size.height + insets.top + insets.bottom
            )
        } action: { size in
            windowSize = size
        }
        .environment(\.onboardingLayout, layout)
        .environment(\.onboardingWindowSize, windowSize)
        .environment(\.onboardingGlyphNamespace, glyphNamespace)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        // Portrait-only on a phone-sized screen, from the welcome on. Not for
        // the splash, which every signed-in launch passes through on its way
        // to Home: holding the phone sideways at launch shouldn't turn the
        // interface upright for a screen with nothing to lay out. Re-checked
        // on every size change, which is what folding or unfolding a foldable
        // produces.
        //
        // Known gap (iPhone Duo, pre-release tooling, 2026-09-25): unfolding
        // after folding releases the lock but iOS leaves the interface
        // portrait — sideways on the inner screen — until the device is
        // turned. Neither `setNeedsUpdateOfSupportedInterfaceOrientations` nor
        // `requestGeometryUpdate(.all)` moved it, and `UIDevice.orientation`
        // reads `.portrait` there, so it can't choose a target. Parked until
        // that hardware ships.
        .onChange(of: OrientationInputs(stage: stage, windowSize: windowSize), initial: true) {
            if stage != .splash, RotationLock.isOnPhoneSizedScreen {
                RotationLock.lockToPortrait()
            } else {
                RotationLock.unlock()
            }
        }
        .onDisappear { RotationLock.unlock() }
    }
}

private struct OrientationInputs: Equatable {
    let stage: OnboardingFlowView.Stage
    let windowSize: CGSize
}

/// The server's login artwork (`/Branding/Splashscreen`), published by the
/// sign-in screen for `OnboardingFlowView`'s background, which sits behind
/// every screen and so can't be owned by any one of them.
struct OnboardingBackdropKey: PreferenceKey {
    static let defaultValue: URL? = nil

    static func reduce(value: inout URL?, nextValue: () -> URL?) {
        value = value ?? nextValue()
    }
}
