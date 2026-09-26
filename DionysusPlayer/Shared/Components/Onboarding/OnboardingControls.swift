import SwiftUI

// MARK: - Glyph

/// The app glyph rendered as Liquid Glass, masked to its own silhouette — the
/// same construction `dionysus.icon` describes, where the "specular" and
/// "translucency" qualities belong to the glyph layer itself rather than to a
/// badge behind it.
///
/// Deliberately still: the splash used to tilt it (and the gradient behind
/// it) with the device, which read as pointless once the glyph became one
/// piece of a composed screen rather than the whole of one. The detail pages'
/// hero keeps its own depth effect (`BackdropLogoOverlay`).
struct DionysusGlassGlyph: View {
    var body: some View {
        Rectangle()
            .modifier(GlassGlyphSurface())
            .mask {
                Image("DionysusGlyph")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            // Always reads as a raised glass badge.
            .shadow(color: .black.opacity(0.4), radius: 24, y: 16)
            .accessibilityHidden(true)
    }
}

private struct GlassGlyphSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .foregroundStyle(.clear)
                .glassEffect(.regular.tint(.white), in: Rectangle())
        } else {
            content
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

extension View {
    /// Joins the flow's one glyph transition, so the glyph moves between
    /// screens instead of cutting. Apply before the glyph's `.frame`.
    func onboardingGlyph() -> some View {
        modifier(OnboardingGlyphMatch())
    }
}

private struct OnboardingGlyphMatch: ViewModifier {
    @Environment(\.onboardingGlyphNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "onboardingGlyph", in: namespace)
        } else {
            content
        }
    }
}

// MARK: - Text

/// A screen title that scales up on iPad while still following Dynamic Type —
/// `@ScaledMetric` relative to Large Title, not a fixed point size.
struct OnboardingTitle: View {
    private let text: Text
    /// The "Dionysus" wordmark: wider, bigger, and never broken across lines.
    private let isWordmark: Bool

    init(_ key: LocalizedStringKey) {
        text = Text(key)
        isWordmark = false
    }

    /// The app's own name, set as the wordmark — not localized.
    init(wordmark: String) {
        text = Text(verbatim: wordmark)
        isWordmark = true
    }

    @Environment(\.onboardingLayout) private var layout
    @ScaledMetric(relativeTo: .largeTitle) private var regularSize: CGFloat = 50
    @ScaledMetric(relativeTo: .largeTitle) private var wordmarkSize: CGFloat = 64

    var body: some View {
        text
            .font(font)
            .fontWidth(isWordmark ? .expanded : nil)
            // The wordmark shrinks to fit rather than breaking mid-word, which
            // it did in a short landscape window's brand pane. Other titles
            // wrap at word boundaries and only shrink as a last resort.
            .lineLimit(isWordmark ? 1 : nil)
            .minimumScaleFactor(isWordmark ? 0.5 : 0.8)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
    }

    private var font: Font {
        guard layout.isRegular else { return .largeTitle.bold() }
        return .system(size: isWordmark ? wordmarkSize : regularSize, weight: .bold)
    }
}

/// Swaps one line of text for another by fading the old one out *before* the
/// new one fades in. `.contentTransition(.opacity)` cross-fades the two on top
/// of each other, which reads as garbled when they wrap to different lengths.
struct FadingText: View {
    let text: String

    @State private var shown: String?
    @State private var opacity = 1.0

    var body: some View {
        Text(shown ?? text)
            .opacity(opacity)
            .onChange(of: text) { _, newText in
                withAnimation(.easeIn(duration: 0.18)) {
                    opacity = 0
                } completion: {
                    shown = newText
                    withAnimation(.easeOut(duration: 0.25)) { opacity = 1 }
                }
            }
    }
}

// MARK: - Buttons

/// The journey's primary action: white glass, burgundy label. White rather
/// than a brand tint, because the brand *is* the background here.
struct OnboardingPrimaryButton: View {
    let title: LocalizedStringKey
    var isBusy = false
    var isEnabled = true
    /// Return presses it — for iPads that live in a keyboard case.
    var isDefaultAction = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView()
                        .tint(Color.dionysusBurgundy)
                        .accessibilityHidden(true)
                }
            }
            .font(.headline)
            .foregroundStyle(isEnabled ? Color.dionysusBurgundy : .white.opacity(0.6))
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .modifier(PrimaryGlassButtonStyle())
        .controlSize(.large)
        .disabled(!isEnabled || isBusy)
        .keyboardShortcut(isDefaultAction ? .defaultAction : nil)
        // Swapping the label for a spinner would otherwise take the button's
        // name with it.
        .accessibilityLabel(Text(title))
    }
}

private struct PrimaryGlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent).tint(.white)
        } else {
            content.buttonStyle(.borderedProminent).tint(.white)
        }
    }
}

struct OnboardingSecondaryButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .modifier(SecondaryGlassButtonStyle())
        .controlSize(.large)
    }
}

private struct SecondaryGlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered).tint(.white)
        }
    }
}

/// The round glass buttons iOS 26 puts in a sheet's top corners, for the
/// hand-built sheets in this journey. Icon-only, but always built from a
/// titled `Button` so VoiceOver has its name.
struct OnboardingCircleButtonStyle: ViewModifier {
    let isProminent: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if isProminent {
                content
                    .buttonStyle(.glassProminent)
                    .tint(.dionysusMagenta)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
            } else {
                content
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
            }
        } else {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        }
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass on iOS 26+, a thin material before it.
    @ViewBuilder
    func onboardingGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

// MARK: - Layout

/// Wraps fixed-width tiles into rows, balanced and centred: five tiles where
/// four fit make 3 + 2, not 4 + 1 with the last one stranded on a row of its
/// own, and a short last row sits under the middle of the one above.
struct CenteredFlowLayout: Layout {
    let itemWidth: CGFloat
    let spacing: CGFloat
    let lineSpacing: CGFloat

    /// The index ranges of each row, for `count` tiles in `width`.
    static func rows(count: Int, itemWidth: CGFloat, spacing: CGFloat, width: CGFloat) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let fits = max(1, Int((width + spacing) / (itemWidth + spacing)))
        let rowCount = (count + fits - 1) / fits
        let perRow = (count + rowCount - 1) / rowCount
        return stride(from: 0, to: count, by: perRow).map { $0..<min($0 + perRow, count) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // All tiles on one row is the natural width. A nil or infinite
        // proposal — a stack measuring flexibility — gets that, not infinity.
        let count = CGFloat(subviews.count)
        let natural = count * itemWidth + max(0, count - 1) * spacing
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        let heights = Self.rows(count: subviews.count, itemWidth: itemWidth, spacing: spacing, width: width).map { row in
            row.map { subviews[$0].sizeThatFits(.init(width: itemWidth, height: nil)).height }.max() ?? 0
        }
        return CGSize(width: width, height: heights.reduce(0, +) + lineSpacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in Self.rows(count: subviews.count, itemWidth: itemWidth, spacing: spacing, width: bounds.width) {
            let rowWidth = CGFloat(row.count) * itemWidth + CGFloat(row.count - 1) * spacing
            var x = bounds.midX - rowWidth / 2
            var rowHeight: CGFloat = 0
            for index in row {
                let size = subviews[index].sizeThatFits(.init(width: itemWidth, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .init(width: itemWidth, height: size.height))
                x += itemWidth + spacing
                rowHeight = max(rowHeight, size.height)
            }
            y += rowHeight + lineSpacing
        }
    }
}
