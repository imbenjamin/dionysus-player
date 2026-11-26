import SwiftUI
import UIKit

/// Presents the changed-certificate warning (#466) over everything, on both
/// platforms: iOS's `CertificateWarningView` from `RootView`, the Apple TV's
/// `TVCertificateWarningPage` from `TVRootView`.
///
/// - **Never over a player.** Playback fails on the refused certificate with
///   a message of its own; the warning waits and shows once the player has
///   gone. `isPlayerUp` is read live (`PlayerCloseRequest` on iOS,
///   `TVPlayerActivity` on the Apple TV), before every try, and a chain
///   holding a player or still in a transition is never dismissed.
/// - **Over anything else.** A sheet or cover already up (iOS's Account
///   sheet, the Apple TV's Profile covers, a question) is closed first: a
///   root presentation over a presenting descendant can be refused, and the
///   warning would stay set with nothing on screen.
/// - **Never set and unseen.** A presentation UIKit refused is tried again
///   (`CertificateWarningPresentationAttempts`). One that can't be shown at
///   all ends as Not Now without consuming the refusal
///   (`AppState.withdrawUnshownCertificateWarning()`). While the app isn't
///   active it waits for it to be.
/// - **The first answer wins**, and is acted on once the page has gone, so a
///   restart or a phase change never lands mid-dismissal. A page closed with
///   no answer while the warning stands (Menu on the Apple TV) is Not Now.
struct CertificateWarningPresentation<Page: View>: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    let isPlayerUp: () -> Bool
    /// A view controller the warning must never dismiss (the Apple TV's
    /// player host); iOS's player is caught by `isPlayerUp`.
    let protects: (UIViewController) -> Bool
    let page: (CertificateWarning, @escaping (CertificateWarningAnswer) -> Void) -> Page

    @State private var presented: CertificateWarning?
    @State private var answer: CertificateWarningAnswer?
    /// The warning whose page has appeared; nil until it has.
    @State private var onScreen: CertificateWarning.ID?
    @State private var presenting: Task<Void, Never>?
    /// `scenePhase == .active`, kept here so the loop's stop and its
    /// restart read the same signal.
    @State private var isSceneActive = true

    /// The warning to show now: none while a player is up.
    private var showable: CertificateWarning? { isPlayerUp() ? nil : appState.certificateWarning }

    func body(content: Content) -> some View {
        content
            .onChange(of: showable, initial: true) { _, warning in
                if let warning {
                    if presented?.id != warning.id { present(warning) }
                } else {
                    // A player came up, or the warning was cleared: stop
                    // trying, and drop a page that never appeared. One held
                    // back by a player comes back through here once it's gone.
                    presenting?.cancel()
                    if appState.certificateWarning == nil || onScreen != presented?.id { presented = nil }
                }
            }
            // Away from the foreground, tries wait (`.inactive`); back, they
            // resume. One signal for both: the loop reads `isSceneActive`.
            .onChange(of: scenePhase, initial: true) { old, phase in
                isSceneActive = phase == .active
                guard old != phase, isSceneActive, let warning = showable, presented?.id != warning.id else { return }
                present(warning)
            }
            .fullScreenCover(item: $presented, onDismiss: dismissed) { warning in
                page(warning) { choice in
                    guard answer == nil else { return }
                    answer = choice
                    presented = nil
                }
                .onAppear { onScreen = warning.id }
            }
    }

    private func present(_ warning: CertificateWarning) {
        presenting?.cancel()
        presenting = Task { @MainActor in
            let attempts = CertificateWarningPresentationAttempts(
                isPlayerUp: isPlayerUp,
                isActive: { isSceneActive },
                isWanted: { appState.certificateWarning?.id == warning.id },
                hasAppeared: { onScreen == warning.id },
                isPresented: { RootPresentations.isPresenting },
                dismissOthers: { await RootPresentations.dismissAll(protecting: protects) },
                present: {
                    answer = nil
                    presented = warning
                },
                withdraw: { presented = nil }
            )
            if await attempts.run() == .gaveUp {
                appState.withdrawUnshownCertificateWarning()
            }
        }
    }

    private func dismissed() {
        let choice = answer
        let wasOnScreen = onScreen != nil
        answer = nil
        onScreen = nil
        switch choice {
        case .trust: Task { await appState.trustPresentedCertificate() }
        case .changeServer: appState.changeServer()
        case .notNow: appState.stayOfflineForNow()
        case nil: if wasOnScreen, appState.certificateWarning != nil { appState.stayOfflineForNow() }
        }
    }
}

/// Trying to put the warning on screen, apart from the views so it can be
/// tested: everything it reads is read live, at each step.
@MainActor
struct CertificateWarningPresentationAttempts {
    enum Outcome: Equatable {
        /// On screen, or presented and still appearing.
        case shown
        /// A player is up; tried again once it has gone.
        case playerUp
        /// The app isn't in the foreground; tried again once it is.
        case inactive
        /// The warning was answered or cleared meanwhile.
        case notWanted
        case cancelled
        /// Nothing could be shown in every try: a genuinely unpresentable
        /// state, which the caller ends as Not Now.
        case gaveUp
    }

    var tries = 5
    /// How long a presentation gets to appear before it counts as refused.
    var settle: Duration = .seconds(1.5)
    var pause: Duration = .milliseconds(300)
    let isPlayerUp: () -> Bool
    let isActive: () -> Bool
    /// The warning still stands.
    let isWanted: () -> Bool
    let hasAppeared: () -> Bool
    /// Anything is presented over the root: the page, presented but not yet
    /// appeared, is left alone (never torn down for being slow).
    let isPresented: () -> Bool
    /// Closes what's above the root; false when it wouldn't (a transition
    /// running, or a protected controller in the chain).
    let dismissOthers: () async -> Bool
    let present: () -> Void
    let withdraw: () -> Void
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func run() async -> Outcome {
        for _ in 0..<tries {
            if let stop = reasonToStop() { return stop }
            if await dismissOthers() {
                if let stop = reasonToStop() { return stop }
                present()
                await sleep(settle)
                if Task.isCancelled { return .cancelled }
                if hasAppeared() || isPresented() { return .shown }
                // Refused: nothing was presented.
                withdraw()
                if let stop = reasonToStop() { return stop }
                await sleep(pause)
            } else {
                // A transition still running (a sheet held mid-drag, a slow
                // cover): as much patience as a refused presentation gets.
                await sleep(settle)
            }
        }
        return reasonToStop() ?? .gaveUp
    }

    private func reasonToStop() -> Outcome? {
        if Task.isCancelled { return .cancelled }
        if !isWanted() { return .notWanted }
        if isPlayerUp() { return .playerUp }
        if !isActive() { return .inactive }
        return nil
    }
}

extension View {
    /// `CertificateWarningPresentation`, from each app's root view.
    func certificateWarning<Page: View>(
        isPlayerUp: @escaping () -> Bool,
        protects: @escaping (UIViewController) -> Bool = { _ in false },
        @ViewBuilder page: @escaping (CertificateWarning, @escaping (CertificateWarningAnswer) -> Void) -> Page
    ) -> some View {
        modifier(CertificateWarningPresentation(isPlayerUp: isPlayerUp, protects: protects, page: page))
    }
}

/// What's presented over the key window's root view controller.
@MainActor
enum RootPresentations {
    static var isPresenting: Bool { rootViewController?.presentedViewController != nil }

    /// Dismisses everything above the root, unanimated, and returns whether
    /// nothing is left (true at once when nothing was presented). Refuses,
    /// returning false, while any presentation in the chain is mid-transition
    /// (a player still coming up is one) or `protecting` claims one. Waits up
    /// to a second for the dismissal: UIKit drops one mid-transition without
    /// calling its completion.
    static func dismissAll(protecting: (UIViewController) -> Bool) async -> Bool {
        guard let root = rootViewController else { return false }
        let chain = presentedChain(of: root)
        guard !chain.isEmpty else { return true }
        guard !chain.contains(where: { $0.isBeingPresented || $0.isBeingDismissed || protecting($0) }) else { return false }
        root.dismiss(animated: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while root.presentedViewController != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return root.presentedViewController == nil
    }

    /// Runs `action` once every presentation in the key window's chain has
    /// finished its transition: after an alert's dismissal, say, whose
    /// `isPresented` SwiftUI clears as the button is tapped, before UIKit
    /// has started taking it away.
    /// Gives up waiting, and runs it, two seconds after being asked.
    static func afterTransitions(_ action: @escaping @MainActor () -> Void) {
        afterTransitions(action, until: ContinuousClock.now.advanced(by: .seconds(2)))
    }

    private static func afterTransitions(_ action: @escaping @MainActor () -> Void, until deadline: ContinuousClock.Instant) {
        let chain = rootViewController.map(presentedChain(of:)) ?? []
        if let coordinator = chain.lazy.compactMap(\.transitionCoordinator).first {
            coordinator.animate(alongsideTransition: nil) { _ in
                Task { @MainActor in afterTransitions(action, until: deadline) }
            }
        } else if ContinuousClock.now < deadline, chain.last is UIAlertController {
            // Its dismissal hasn't started yet: look again a frame later.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) {
                afterTransitions(action, until: deadline)
            }
        } else {
            action()
        }
    }

    private static func presentedChain(of root: UIViewController) -> [UIViewController] {
        var chain: [UIViewController] = []
        var next = root.presentedViewController
        while let controller = next {
            chain.append(controller)
            next = controller.presentedViewController
        }
        return chain
    }

    private static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }
}
