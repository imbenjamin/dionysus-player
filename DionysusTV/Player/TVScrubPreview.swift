import SwiftUI

/// The trickplay still above the scrub head, with "52:15 · Chapter" under
/// it (prototype screen 12). Without trickplay only the caption shows.
struct TVScrubPreview: View {
    let image: CGImage?
    let showsFrame: Bool
    let caption: String
    /// The scan's level, -4 to 4, while scanning; `nil` in a free scrub.
    var scanLevel: Int? = nil

    static let size = CGSize(width: 400, height: 225)

    var body: some View {
        VStack(spacing: 12) {
            if showsFrame {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(Color.black)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.6), radius: 25, y: 20)
            }
            HStack(spacing: 12) {
                if let scanLevel {
                    TVScanIndicator(level: scanLevel)
                }
                Text(caption)
                    .monospacedDigit()
                    .lineLimit(1)
            }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55), in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityIdentifier(A11yID.TV.Player.scrubPreview)
    }
}

/// The scan's glyph: chevrons pointing the way it runs, one more per level
/// (two at level 1, four at level 3), or a pause glyph at a stop. No speed
/// number; the glyphs say enough (Benjamin, 2026-10-06).
struct TVScanIndicator: View {
    let level: Int

    static func glyphCount(level: Int) -> Int {
        level == 0 ? 1 : abs(level) + 1
    }

    var body: some View {
        HStack(spacing: -6) {
            if level == 0 {
                Image(systemName: "pause.fill")
            } else {
                ForEach(0..<Self.glyphCount(level: level), id: \.self) { _ in
                    Image(systemName: level < 0 ? "arrowtriangle.backward.fill" : "arrowtriangle.forward.fill")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level == 0 ? String(localized: "Scan stopped") : String(localized: "Scanning"))
        // The level itself, unlocalized, for the UI tests.
        .accessibilityValue("\(level)")
        .accessibilityIdentifier(A11yID.TV.Player.scanIndicator)
    }
}
