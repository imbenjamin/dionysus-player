import SwiftUI

/// The compact Next Up card (prototype screen 15; Benjamin's settled call):
/// the thumb with a seconds chip and a countdown bar, "S1:E4 · Title", then
/// Play Now and Close. Nothing else.
struct TVNextUpCard: View {
    let episode: MediaItem
    let secondsRemaining: Int
    let totalSeconds: Int
    /// `nil` while the transport is up and the card has no focus.
    let focus: TVNextUpButton?
    /// Set in the accessible transport (M5): the buttons are focusable and
    /// send this, drawn from the focus engine's focus instead of `focus`.
    var send: ((TVNextUpButton) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bar glides rather than stepping with the whole seconds
    /// (Benjamin, 2026-10-07): the count truncates, so when it reads `n`
    /// about `n + 1` seconds remain, and the bar runs from there to `n`
    /// over the next second.
    @State private var barFraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .topTrailing) {
                AsyncRemoteImage(url: episode.thumbImageURL ?? episode.primaryImageURL, placeholderSystemImage: "play.tv")
                    .frame(width: 420, height: 236)
                    .accessibilityHidden(true)
                Text("\(secondsRemaining)s")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(12)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.25))
                        Rectangle().fill(Color.dionysusAmber).frame(width: geo.size.width * (barFraction ?? fraction(secondsRemaining + 1)))
                    }
                    .frame(height: 8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .accessibilityHidden(true)
            }
            .frame(width: 420, height: 236)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            // Drawn first at `n + 1` (the `nil` fallback), so the first
            // second glides too.
            .onAppear { glide(to: secondsRemaining) }
            .onChange(of: secondsRemaining) { _, seconds in glide(to: seconds) }
            Text(episode.kind == .episode ? episode.numberedEpisodeName : episode.railTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 4)
            HStack(spacing: 12) {
                button(.playNow, "Play Now", systemImage: "play.fill", id: A11yID.TV.Player.nextUpPlayNow)
                    .frame(maxWidth: .infinity)
                button(.close, "Close", systemImage: nil, id: A11yID.TV.Player.nextUpClose)
            }
        }
        .padding(20)
        .frame(width: 460)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.TV.Player.nextUpCard)
    }

    private func fraction(_ seconds: Int) -> Double {
        totalSeconds > 0 ? min(1, max(0, Double(seconds) / Double(totalSeconds))) : 0
    }

    private func glide(to seconds: Int) {
        if reduceMotion {
            barFraction = fraction(seconds)
        } else {
            withAnimation(.linear(duration: 1)) { barFraction = fraction(seconds) }
        }
    }

    @ViewBuilder
    private func button(_ which: TVNextUpButton, _ title: LocalizedStringKey, systemImage: String?, id: String) -> some View {
        if let send {
            TVPlayerControlButton(action: { send(which) }) { focused in
                face(title, systemImage: systemImage, isFocused: focused)
            }
            .accessibilityIdentifier(id)
        } else {
            face(title, systemImage: systemImage, isFocused: focus == which)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(id)
        }
    }

    private func face(_ title: LocalizedStringKey, systemImage: String?, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(title)
        }
        // The swipe-down panel's button scale (Benjamin, 2026-10-07).
        .font(.callout.weight(.semibold))
        .foregroundStyle(isFocused ? Color.black : Color.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: systemImage == nil ? nil : .infinity)
        .background(Capsule().fill(isFocused ? Color.white : Color.white.opacity(0.18)))
        .accessibilityElement(children: .combine)
    }
}
