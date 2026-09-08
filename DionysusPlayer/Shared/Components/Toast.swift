import SwiftUI

/// A brief, self-dismissing confirmation — the app's answer to "that worked"
/// for an action whose own UI has already gone away by the time it finishes.
///
/// Exists because the first thing it confirms (adding an item to a playlist)
/// completes by *dismissing* its own sheet, leaving nothing on screen that
/// could show a result. A haptic alone was tried first and isn't enough:
/// it says something happened, not what, and says nothing at all to a user
/// who has haptics off or can't feel them.
///
/// Deliberately not an alert or a `confirmationDialog`. Those interrupt and
/// demand a tap; this is a report, not a question, and Apple's own apps
/// (Photos' "Saved", Music's "Added to Playlist") answer the same situation
/// the same way.
struct Toast: Equatable, Identifiable {
    let id = UUID()
    /// Already localized — this is constructed in view-model/action code,
    /// which can't use `LocalizedStringKey`.
    var message: String
    var systemImage: String = "checkmark.circle.fill"

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// Where a toast is posted to, and where `ToastHost` reads it from.
///
/// A singleton for the same reason `ConnectivityMonitor` is one: the thing
/// posting (`AddToPlaylistSheet`, inside a sheet, inside a toolbar item) and
/// the thing displaying it (`MainTabView`'s overlay) are nowhere near each
/// other in the view tree, and threading a binding between them would mean
/// a closure parameter on every view in between.
///
/// Writes are rare — one per completed user action — so this doesn't need
/// the guard-before-write discipline a frequently-written `@Observable`
/// singleton does. The read is deliberately confined to `ToastHost` so that
/// posting one re-renders that small view rather than the whole tab view it
/// hangs off.
@MainActor
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var current: Toast?

    /// How long a toast stays up. Long enough to read a short sentence
    /// without becoming something the user has to wait out.
    static let visibleDuration: Duration = .seconds(2.5)

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func post(_ toast: Toast) {
        // Replacing rather than queueing: two confirmations in quick
        // succession means the second is the one that matters, and a queue
        // would make the user wait out a message about something they've
        // already moved on from.
        dismissTask?.cancel()
        current = toast

        // VoiceOver can't see something that disappears on its own before
        // focus reaches it, so the message is announced rather than left to
        // be discovered. `.announcement` deliberately, not
        // `.screenChanged` — nothing about the screen's structure changed,
        // and a screen-change notification would move focus.
        AccessibilityNotification.Announcement(toast.message).post()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    /// Clears immediately, cancelling any pending auto-dismiss. Used by the
    /// tap-to-dismiss gesture on the toast itself.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }

    #if DEBUG
    /// Test seam — `ToastCenter` is a process-wide singleton, so a UI test
    /// or preview that posts one would otherwise leak it into whatever runs
    /// next.
    func reset() { dismiss() }
    #endif
}

/// Renders whatever `ToastCenter.shared` currently holds.
///
/// Kept as its own view, applied once as an overlay in `MainTabView`, for
/// two reasons: it is the only thing that reads `ToastCenter.current`, so a
/// post re-renders this and nothing else; and an overlay at that level sits
/// above the tab bar and above any pushed screen, which is where a
/// confirmation belongs — a toast attached to the screen that raised it
/// would vanish the moment that screen did.
///
/// **Anchored to the top, and deliberately so** (changed from the bottom
/// after on-device review, 2026-09-08). Top is the iOS convention for a
/// transient banner — AirPods connection, Apple Pay, incoming
/// notifications all drop from there; a bottom-anchored toast is the
/// Android/Material snackbar pattern, which is the only reason it was tried
/// first. It also lands where the user is already looking: every action
/// that currently posts one is triggered from the trailing *toolbar*, at
/// the top of the screen. Don't move it back without a reason that beats
/// both of those.
struct ToastHost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var toast: Toast? { ToastCenter.shared.current }

    var body: some View {
        VStack {
            if let toast {
                content(for: toast)
                    .transition(transition)
                    .padding(.top, Self.navigationBarClearance)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        // Never intercepts taps except on the toast itself — an overlay
        // spanning the whole screen would otherwise swallow every tap
        // underneath it for the entire time a toast is up.
        .allowsHitTesting(toast != nil)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: toast)
    }

    /// Enough to clear a standard inline navigation bar, measured below the
    /// top safe area the overlay is already inset by.
    ///
    /// A fixed number rather than something derived: this overlay hangs off
    /// `MainTabView`, above every `NavigationStack`, so there is nothing in
    /// scope that knows how tall the current screen's bar is. 8pt was tried
    /// first and put the capsule squarely *in* the toolbar row, between the
    /// back button and the trailing actions (seen on device, 2026-09-08) —
    /// covering the very control the user just tapped.
    private static let navigationBarClearance: CGFloat = 52

    private func content(for toast: Toast) -> some View {
        capsule(around: label(for: toast))
            .onTapGesture { ToastCenter.shared.dismiss() }
            // One element, not a glyph plus a label: the glyph is decorative
            // (it repeats what the text says), and left to itself VoiceOver
            // would read its SF Symbol name aloud — the exact failure
            // `AccessibilityAuditTests` gates on.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(toast.message)
            .accessibilityIdentifier(A11yID.Toast.message)
    }

    private func label(for toast: Toast) -> some View {
        HStack(spacing: 10) {
            // The one explicit colour here. A brand accent on a filled
            // symbol reads against both a light and a dark backdrop, and
            // unlike the text below it carries no meaning of its own to
            // lose if the contrast pass leaves it alone.
            Image(systemName: toast.systemImage)
                .font(.headline)
                .foregroundStyle(Color.dionysusHighlight)
            // Deliberately sets **no** foreground style. See `capsule(around:)`.
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Wraps the label *in* the glass rather than putting glass behind it,
    /// which is the whole point.
    ///
    /// This started as `.background(Capsule().fill(.clear).glassEffect(...))`
    /// and shipped to a device looking wrong: dark text on a dark backdrop,
    /// with none of the automatic inversion Liquid Glass is supposed to do.
    /// The reason is exactly what `HeroToolbarGlyph`'s doc comment records
    /// for the toolbar glyphs — real `.glassEffect` *content* gets tinted
    /// for contrast against whatever is currently behind the glass, and
    /// content merely sitting on top of a glass-filled shape is not that
    /// content. It has to be the modified view itself, and it must set no
    /// explicit foreground colour, or the tinting has nothing to do.
    @ViewBuilder
    private func capsule(around content: some View) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            // No live-contrast mechanism to defer to below 26 — the same
            // split `HeroToolbarGlyph` makes. A thicker material than the
            // glass path's translucency keeps `.primary` text legible over
            // arbitrary artwork.
            content.background(Capsule().fill(.thickMaterial))
        }
    }

    private var transition: AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: .top).combined(with: .opacity)
    }
}
