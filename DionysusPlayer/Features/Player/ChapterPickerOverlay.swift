import SwiftUI

/// The player's chapter list — a hand-rolled panel, deliberately not a
/// `.sheet`/`.popover`/`Menu`, for exactly the reasons
/// `PlayerControlsOverlay.trackSelectionButton`'s doc comment lays out at
/// length for the audio/subtitle picker it's modeled on: system presentation
/// chrome over video brings its own background/arrow/transition layers that
/// visibly desync from this app's own dark player chrome, and a `Menu`'s
/// width and font can't be controlled at all.
///
/// Lives in its own file rather than as another section of
/// `PlayerControlsOverlay` purely for size — that view is already 1500+
/// lines and carries the entire transport chrome. Its visibility is a
/// `@Binding` owned by `PlayerView` for the same reason
/// `isShowingTrackPicker` is: the auto-hide timer has to know this is open,
/// or it fades the whole controls row (this panel included) out from under
/// someone reading it. See `PlayerView.scheduleAutoHide()`.
struct ChapterPickerOverlay: View {
    let chapters: [Chapter]
    /// Highlighted as the current selection — `PlayerViewModel
    /// .currentChapter`, i.e. wherever the playhead actually is, not
    /// whatever was last tapped.
    let currentChapter: Chapter?
    var onSelect: (Chapter) -> Void

    /// Matches `PlayerControlsOverlay`'s own picker sizing constants rather
    /// than inventing a second set — the two panels appear in the same
    /// player chrome and should read as the same component.
    static let idealWidth: CGFloat = 320
    static let maxWidth: CGFloat = 360

    /// Shared with `PlayerControlsOverlay`'s open/close toggles so this
    /// panel's appearance/dismissal feels identical to the track picker's.
    static let animation: Animation = .easeOut(duration: 0.18)

    /// Landscape iPhone (this player's primary orientation) is only ~380-430pt
    /// tall in total — nowhere near enough headroom for a 320pt-tall panel
    /// anchored `.bottomLeading` under `PlayerControlsOverlay.chapterButton`
    /// (320pt content + the padding clearing that button pushes its *top*
    /// edge off the top of the screen entirely, confirmed live on a physical
    /// device). Portrait keeps the original 320pt cap — plenty of headroom
    /// there — so this only kicks in for the orientation that actually needs
    /// it. `verticalSizeClass`, not a `GeometryReader` measurement of this
    /// view's own size: see `estimatedHeight`'s doc comment just below for
    /// why that specific approach is a known dead end in this exact view.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }
    private var maxHeight: CGFloat { isLandscape ? 180 : 320 }

    private static let thumbnailWidth: CGFloat = 80
    /// One row's height — a 80×45 (16:9) thumbnail plus `.padding(.vertical,
    /// 10)` either side, which comfortably clears the two stacked text lines
    /// beside it.
    ///
    /// `@ScaledMetric` for the same reason `PlayerControlsOverlay`'s row
    /// heights are (see `navigationRowHeight` there): `estimatedHeight`
    /// below sizes the panel, and a fixed point value under-estimates real
    /// rows further and further as Dynamic Type grows. Less visible here
    /// than in the track picker only because a feature-length film has
    /// enough chapters that the estimate clears `maxHeight` anyway and the
    /// cap binds instead — but a short chapter list takes the estimate
    /// directly, and would clip exactly the same way.
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 65
    private static let dividerHeight: CGFloat = 1

    /// A deterministic, synchronous *estimate*, not a measurement — for
    /// exactly the reasons `PlayerControlsOverlay.estimatedHeight(for:)`
    /// documents at length for the track picker: every
    /// `GeometryReader`/`PreferenceKey` measurement attempt inside this
    /// view's conditionally-mounted, animated-transition,
    /// nested-in-an-`.overlay` context ended with the panel rendering at
    /// zero size. Row count is known synchronously, so an arithmetic height
    /// has no equivalent "stuck at zero" failure mode; the cost is that a
    /// two-line chapter name makes its row slightly taller than estimated,
    /// which just means a little extra scroll headroom inside a `ScrollView`
    /// that's already scrolling.
    private var estimatedHeight: CGFloat {
        let count = CGFloat(chapters.count)
        return rowHeight * count + Self.dividerHeight * max(0, count - 1)
    }

    var body: some View {
        // A plain `ScrollView`, not a `List` — same reasoning as the track
        // picker: `List` brings its own translucent system background that
        // reads poorly over video, and its separators are trivially
        // hand-rolled here instead.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        if index > 0 { divider }
                        row(for: chapter)
                            .id(chapter.id)
                    }
                }
            }
            // Opens scrolled to wherever playback actually is, rather than
            // at chapter 1 — for a feature-length movie deep into its
            // runtime, the useful part of this list is nowhere near the top.
            // `.onAppear`, not `.task`: this panel is mounted/unmounted by
            // its own conditional, so appearance is exactly the moment to
            // position it, and there's nothing async to await.
            .onAppear {
                guard let currentChapter else { return }
                proxy.scrollTo(currentChapter.id, anchor: .center)
            }
        }
        .frame(idealWidth: Self.idealWidth, maxWidth: Self.maxWidth)
        // An explicit height, not `maxHeight` + `.fixedSize` — see
        // `estimatedHeight`. A short chapter list shrinks the panel to fit
        // rather than leaving dead space below the last row.
        .frame(height: min(estimatedHeight, maxHeight), alignment: .top)
        .clipped()
        .foregroundStyle(.white)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    /// Thumbnail + name/timestamp, closer to `navigationRow`'s two-line
    /// shape than `selectionRow`'s leading checkmark — a chapter list is
    /// browsed visually (which scene is this?), so the still frame carries
    /// more than a checkmark column would, and the current chapter is marked
    /// by a highlighted row background instead.
    private func row(for chapter: Chapter) -> some View {
        let isCurrent = chapter.id == currentChapter?.id
        return Button {
            onSelect(chapter)
        } label: {
            HStack(spacing: 12) {
                thumbnail(for: chapter)
                    .frame(width: Self.thumbnailWidth, height: Self.thumbnailWidth * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.name)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    // A bare timecode — formatted data, not localizable
                    // prose (CLAUDE.md).
                    Text(ChapterTimeFormatter.string(from: chapter.startSeconds))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isCurrent ? Color.white.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.ignore` on the label content, with the selected state exposed as
        // a trait rather than left to a background color a screen reader
        // can't perceive — same treatment `selectionRow`'s checkmark gets.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "\(chapter.name), starts at \(ChapterTimeFormatter.spokenString(from: chapter.startSeconds))")
        )
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// Same online/offline split as `ChapterCard`'s — see `Chapter.imageURL`.
    @ViewBuilder
    private func thumbnail(for chapter: Chapter) -> some View {
        if let url = chapter.imageURL, url.isFileURL {
            LocalFileImage(
                url: url,
                targetSize: CGSize(width: Self.thumbnailWidth, height: Self.thumbnailWidth * 9 / 16),
                placeholderSystemImage: "film",
                glyphSize: 16
            )
        } else {
            AsyncRemoteImage(url: chapter.imageURL, placeholderSystemImage: "film", glyphSize: 16)
        }
    }

    private var divider: some View {
        Divider().overlay(Color.white.opacity(0.15))
    }
}
