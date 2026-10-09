import SwiftUI

extension TVPanelTab {
    var title: String {
        switch self {
        case .info: String(localized: "Info")
        case .chapters: String(localized: "Chapters")
        case .audio: String(localized: "Audio")
        case .subtitles: String(localized: "Subtitles")
        }
    }
}

/// The swipe-down panel (prototype screen 13, without its Stats tab): the
/// tabs, then the tab's content. Drawn from the model's state; it takes no
/// focus of its own.
struct TVPlayerPanelView: View {
    let viewModel: PlayerViewModel
    let panel: TVPlayerInputState.Panel
    let tabs: [TVPanelTab]
    /// The accessible transport (M5): tabs and rows are focusable buttons
    /// sending `send`, drawn from the focus engine's focus.
    var accessible = false
    var send: (TVPlayerControl) -> Void = { _ in }
    /// The row focus lands on as the panel opens in the accessible
    /// transport: Restart, the current chapter, the chosen track, as the
    /// remote's Down does (`TVPlayerInputModel.defaultIndex`).
    var landingRow = 0
    @FocusState private var focusedRow: Int?

    private func isFocused(_ index: Int) -> Bool { panel.focus == .content(index) }

    /// A button the focus engine reaches in the accessible transport;
    /// otherwise the face drawn from the model's focus.
    @ViewBuilder
    private func control<Face: View>(
        _ action: TVPlayerControl, modelFocused: Bool, @ViewBuilder face: @escaping (_ isFocused: Bool) -> Face
    ) -> some View {
        if accessible {
            let row: Int? = if case .panelRow(let index) = action { index } else { nil }
            TVPlayerControlButton(action: { send(action) }, label: face)
                .focused($focusedRow, equals: row)
        } else {
            face(modelFocused)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            HStack(spacing: 12) {
                ForEach(tabs, id: \.self) { tab in
                    control(.openPanel(tab), modelFocused: panel.focus == .tabs && tab == panel.tab) { focused in
                        Text(tab.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(focused ? Color.black : Color.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(focused ? Color.white : Color.white.opacity(tab == panel.tab ? 0.2 : 0))
                            )
                    }
                    .accessibilityAddTraits(tab == panel.tab ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier(A11yID.TV.Player.panelTab(tab.id))
                }
            }
            .focusSection()
            // One height for every tab, so switching tabs moves nothing
            // above it.
            content
                .frame(maxWidth: .infinity, minHeight: 330, maxHeight: 330, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.TV.Player.panel)
        .onAppear { if accessible { focusedRow = landingRow } }
    }

    @ViewBuilder
    private var content: some View {
        switch panel.tab {
        case .info: info
        case .chapters: chapters
        case .audio: trackList(rows: viewModel.audioTracks.map { ($0.title, $0.metadata, $0.isSelected) })
        case .subtitles:
            trackList(rows: [(String(localized: "Off"), nil, !viewModel.subtitleTracks.contains(where: \.isSelected))]
                + viewModel.subtitleTracks.map { ($0.title, $0.metadata, $0.isSelected) })
        }
    }

    // MARK: Info

    @ViewBuilder
    private var info: some View {
        if let item = viewModel.item {
            let art = TVPlayerInfoArt(item: item)
            HStack(alignment: .top, spacing: 40) {
                AsyncRemoteImage(url: art.url, placeholderSystemImage: item.kind.placeholderSystemImage)
                    .frame(width: art.shape.size.width, height: art.shape.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityElement()
                    .accessibilityLabel(String(localized: "Artwork"))
                    .accessibilityIdentifier(A11yID.TV.Player.infoArt)
                // Fits the prototype's 370pt below the tabs, an episode's
                // extra name line included.
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.kind == .episode ? (item.dto.seriesName ?? item.railTitle) : item.railTitle)
                        .font(.headline)
                    if item.kind == .episode {
                        Text(item.numberedEpisodeName).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(TVDetailFormat.metadata(for: item).joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let overview = item.dto.overview {
                        Text(overview).font(.subheadline).lineLimit(3).frame(maxWidth: 900, alignment: .leading)
                    }
                    control(.panelRow(0), modelFocused: isFocused(0)) { focused in
                        Label("Restart", systemImage: "arrow.counterclockwise")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(focused ? Color.black : Color.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(focused ? Color.white : Color.white.opacity(0.18)))
                    }
                    .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier(A11yID.TV.Player.restart)
                }
            }
        }
    }

    // MARK: Chapters

    private var chapters: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(Array(viewModel.chapters.enumerated()), id: \.element.id) { index, chapter in
                        control(.panelRow(index), modelFocused: isFocused(index)) { focused in
                            chapterTile(chapter, index: index, focused: focused)
                        }
                        .id(index)
                    }
                }
            }
            .scrollClipDisabled()
            .onChange(of: panel.focus, initial: true) { _, focus in
                if case .content(let index) = focus { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
    }

    private func chapterTile(_ chapter: Chapter, index: Int, focused: Bool) -> some View {
        let current = viewModel.currentChapter?.id == chapter.id
        return VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                if let url = chapter.imageURL {
                    AsyncRemoteImage(url: url, placeholderSystemImage: "film")
                } else {
                    TVChapterTrickplayFrame(viewModel: viewModel, seconds: chapter.startSeconds)
                }
                if current { Color.black.opacity(0.25) }
                // Watched chapters fill the bar; the current one fills as
                // far as the playhead (Benjamin, 2026-10-06).
                let progress = chapterProgress(index)
                if progress > 0 {
                    GeometryReader { geo in
                        Rectangle().fill(Color.dionysusAmber)
                            .frame(width: geo.size.width * progress, height: 8)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(width: 380, height: 214)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white, lineWidth: focused ? 4 : 0))
            .scaleEffect(focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
            HStack(spacing: 12) {
                Text(chapter.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if current {
                    Text("NOW")
                        .font(.caption2.bold())
                        .foregroundStyle(Color(red: 0.08, green: 0.03, blue: 0.06))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.dionysusAmber, in: Capsule())
                }
            }
            Text(TVPlaybackTimeFormat.string(chapter.startSeconds)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 380, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chapter.name)
        .accessibilityValue(TVPlaybackTimeFormat.string(chapter.startSeconds))
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(A11yID.TV.Player.panelRow(TVPanelTab.chapters.id, index))
    }

    private func chapterProgress(_ index: Int) -> Double {
        Self.chapterProgress(
            index, starts: viewModel.chapters.map(\.startSeconds),
            duration: viewModel.duration, currentTime: viewModel.currentTime
        )
    }

    /// How far the playhead is through chapter `index`: 1 for a chapter
    /// already passed, 0 for one not reached.
    static func chapterProgress(
        _ index: Int, starts: [TimeInterval], duration: TimeInterval, currentTime: TimeInterval
    ) -> Double {
        guard starts.indices.contains(index) else { return 0 }
        let start = starts[index]
        let end = index + 1 < starts.count ? starts[index + 1] : duration
        guard end > start else { return 0 }
        return min(1, max(0, (currentTime - start) / (end - start)))
    }

    // MARK: Tracks

    /// iOS's picker text, two lines a track: the title, then the metadata
    /// line (`PlaybackTrack.metadata`), with a tick on the chosen one.
    private func trackList(rows: [(title: String, metadata: String?, isChosen: Bool)]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        control(.panelRow(index), modelFocused: isFocused(index)) { focused in
                            HStack(spacing: 20) {
                                Image(systemName: "checkmark")
                                    .font(.callout.weight(.semibold))
                                    .opacity(row.isChosen ? 1 : 0)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title).font(.callout.weight(.semibold))
                                    if let metadata = row.metadata {
                                        Text(metadata).font(.caption).opacity(0.7)
                                    }
                                }
                            }
                            .foregroundStyle(focused ? Color.black : Color.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .frame(width: 760, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 20).fill(focused ? Color.white : Color.clear))
                        }
                        .id(index)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(row.isChosen ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier(A11yID.TV.Player.panelRow(panel.tab.id, index))
                    }
                }
            }
            .frame(height: 330)
            .onChange(of: panel.focus, initial: true) { _, focus in
                if case .content(let index) = focus { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
    }
}

/// A chapter with no image of its own: the trickplay frame at its start.
private struct TVChapterTrickplayFrame: View {
    let viewModel: PlayerViewModel
    let seconds: Double
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            MediaPlaceholderBox(systemImage: "film", isSettled: !viewModel.supportsScrubThumbnails)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .task(id: seconds) {
            guard viewModel.supportsScrubThumbnails else { return }
            image = await viewModel.scrubThumbnail(atSeconds: seconds)
        }
    }
}
