import SwiftUI

/// The player's chapter list: a hand-rolled panel rather than a
/// `.sheet`/`.popover`/`Menu`, for the reasons
/// `PlayerControlsOverlay.trackSelectionButton` gives for the audio/subtitle
/// picker it's modeled on — system presentation chrome over video brings
/// background/arrow/transition layers that desync from this app's dark player
/// chrome, and a `Menu`'s width and font can't be controlled.
///
/// In its own file for size, not separation: `PlayerControlsOverlay` already
/// carries the entire transport chrome. Its visibility is a `@Binding` owned by
/// `PlayerView`, like `isShowingTrackPicker`, because the auto-hide timer must
/// know it's open or it fades the controls row out from under someone reading it.
/// See `PlayerView.scheduleAutoHide()`.
struct ChapterPickerOverlay: View {
    let chapters: [Chapter]
    /// Highlighted as the current selection: `PlayerViewModel.currentChapter`,
    /// where the playhead is rather than what was last tapped.
    let currentChapter: Chapter?
    var onSelect: (Chapter) -> Void

    /// Matches `PlayerControlsOverlay`'s picker sizing constants rather than
    /// inventing a second set: the two panels should read as one component.
    static let idealWidth: CGFloat = 320
    static let maxWidth: CGFloat = 360

    /// Shared with `PlayerControlsOverlay`'s open/close toggles, so this panel
    /// appears and dismisses identically to the track picker.
    static let animation: Animation = .easeOut(duration: 0.18)

    /// Landscape iPhone, this player's primary orientation, is only ~380-430pt
    /// tall — not enough for a 320pt panel anchored `.bottomLeading` under
    /// `PlayerControlsOverlay.chapterButton`, whose content plus the padding
    /// clearing that button pushes its top edge off screen. Portrait keeps the
    /// 320pt cap. `verticalSizeClass` rather than a `GeometryReader` measurement;
    /// see `estimatedHeight` for why that's a dead end here.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }
    private var maxHeight: CGFloat { isLandscape ? 180 : 320 }

    private static let thumbnailWidth: CGFloat = 80
    /// One row's height: an 80×45 thumbnail plus 10pt vertical padding either
    /// side, which clears the two stacked text lines beside it.
    ///
    /// `@ScaledMetric` for the same reason as `PlayerControlsOverlay`'s row
    /// heights: `estimatedHeight` sizes the panel from it, and a fixed point
    /// under-estimates rows further as Dynamic Type grows. A feature-length film
    /// masks that, since its chapter count makes `maxHeight` bind, but a short
    /// list takes the estimate directly and would clip.
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 65
    private static let dividerHeight: CGFloat = 1

    /// A synchronous estimate, not a measurement, for the reasons
    /// `PlayerControlsOverlay.estimatedHeight(for:)` documents: every
    /// `GeometryReader`/`PreferenceKey` attempt inside this conditionally-mounted,
    /// animated, `.overlay`-nested context rendered the panel at zero size. Row
    /// count is known synchronously, so arithmetic has no such failure mode; the
    /// cost is a two-line chapter name making its row slightly taller than
    /// estimated, which just adds scroll headroom.
    private var estimatedHeight: CGFloat {
        let count = CGFloat(chapters.count)
        return rowHeight * count + Self.dividerHeight * max(0, count - 1)
    }

    var body: some View {
        // A plain `ScrollView`, not a `List`, as in the track picker: `List`
        // brings a translucent system background that reads poorly over video, and
        // its separators are trivially hand-rolled.
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
            // Opens scrolled to where playback is rather than chapter 1: deep into
            // a feature-length movie, the useful part of this list is nowhere near
            // the top. `.onAppear`, not `.task`: this panel is mounted by a
            // conditional, so appearance is the moment to position it, and there's
            // nothing to await.
            .onAppear {
                guard let currentChapter else { return }
                proxy.scrollTo(currentChapter.id, anchor: .center)
            }
        }
        .frame(idealWidth: Self.idealWidth, maxWidth: Self.maxWidth)
        // An explicit height, not `maxHeight` plus `.fixedSize` (see
        // `estimatedHeight`), so a short chapter list shrinks the panel rather
        // than leaving dead space below the last row.
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
        .accessibilityIdentifier(A11yID.Player.chapterPicker)
    }

    /// Thumbnail plus name and timestamp, closer to `navigationRow`'s two-line
    /// shape than `selectionRow`'s leading checkmark: a chapter list is browsed
    /// visually, so the still frame carries more than a checkmark column, and the
    /// current chapter is marked by a highlighted row background.
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
                    // A bare timecode: formatted data, not localizable prose.
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
        // `.ignore` on the label content, with the selected state exposed as a
        // trait rather than a background color a screen reader can't perceive —
        // as `selectionRow`'s checkmark does.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "\(chapter.name), starts at \(ChapterTimeFormatter.spokenString(from: chapter.startSeconds))")
        )
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(A11yID.Player.chapterOption(chapter.index))
    }

    /// Same online/offline split as `ChapterCard`; see `Chapter.imageURL`.
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
