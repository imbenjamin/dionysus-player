import Foundation

extension TVPlayerInputModel {
    /// The swipe-down panel. `nil` when it isn't open, or for Play/Pause,
    /// which the transport handles with the panel up.
    static func reducePanel(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext
    ) -> [TVPlayerCommand]? {
        guard var panel = state.panel else { return nil }
        let count = contentCount(panel.tab, context)
        switch (intent, panel.focus) {
        case (.menu, _):
            state.panel = nil
            return []
        case (.playPause, _):
            return nil
        case (.up, .tabs):
            state.panel = nil
            state.transportFocus = .scrubber
            return []
        case (.down, .tabs), (.select, .tabs):
            if count > 0 { panel.focus = .content(defaultIndex(panel.tab, context)) }
        case (.arrow(let direction), .tabs):
            panel.tab = neighbour(of: panel.tab, direction, in: availableTabs(context))
        case (.up, .content(let index)) where panel.tab == .audio:
            panel.focus = audioUp(from: index, context)
        case (.down, .content(let index)) where panel.tab == .audio:
            panel.focus = audioDown(from: index, context)
        case (.arrow(let direction), .content(let index)) where panel.tab == .audio:
            let (focus, commands) = audioArrow(direction, at: index, context)
            panel.focus = focus
            state.panel = panel
            return commands
        case (.up, .content(let index)):
            panel.focus = panel.tab.isList && index > 0 ? .content(index - 1) : .tabs
        case (.down, .content(let index)):
            if panel.tab.isList, index + 1 < count { panel.focus = .content(index + 1) }
        case (.arrow(let direction), .content(let index)):
            if panel.tab == .chapters, count > 0 {
                panel.focus = .content(min(max(index + (direction == .left ? -1 : 1), 0), count - 1))
            }
        case (.select, .content(let index)):
            let (commands, closes) = activateRow(panel.tab, index, context)
            state.panel = closes ? nil : panel
            return commands
        case (.holdBegan, _), (.swipeBegan, _), (.swipeMoved, _), (.swipeEnded, _), (.swipeStep, _):
            // A hold's release arrives as one press; a swipe in the panel
            // arrives as an arrow (`reduce`), so nothing scrubs behind it.
            break
        }
        state.panel = panel
        return []
    }

    static func openPanel(
        _ tab: TVPanelTab, focus: TVPlayerInputState.Panel.Focus, _ state: inout TVPlayerInputState, now: TimeInterval
    ) {
        state.chrome = .transport
        state.transportFocus = .scrubber
        state.panel = .init(tab: tab, focus: focus, lastInputAt: now)
    }

    /// Chapters only when the title has them.
    static func availableTabs(_ context: TVPlayerContext) -> [TVPanelTab] {
        TVPanelTab.allCases.filter { $0 != .chapters || !context.chapterStarts.isEmpty }
    }

    static func neighbour(of tab: TVPanelTab, _ direction: TVDirection, in tabs: [TVPanelTab]) -> TVPanelTab {
        guard let index = tabs.firstIndex(of: tab) else { return tabs.first ?? tab }
        let next = index + (direction == .left ? -1 : 1)
        return tabs.indices.contains(next) ? tabs[next] : tab
    }

    static func contentCount(_ tab: TVPanelTab, _ context: TVPlayerContext) -> Int {
        switch tab {
        case .info: 1
        case .chapters: context.chapterStarts.count
        case .audio: context.audioTrackIDs.count + offsetRowCount(context)
        case .subtitles: context.subtitleTrackIDs.count + 1
        }
    }

    /// The Audio tab's row at `index`: the tracks, then (while the offset can
    /// apply) the scope, offset and Reset rows (Benjamin, 2026-10-18: the
    /// scope sits under the heading, above what it governs).
    static func audioRow(at index: Int, _ context: TVPlayerContext) -> TVAudioPanelRow? {
        let tracks = context.audioTrackIDs.count
        if index >= 0, index < tracks { return .track(index) }
        guard context.audioOffset != nil else { return nil }
        switch index - tracks {
        case 0: return .scope
        case 1: return .offset
        case 2: return offsetRowCount(context) == 3 ? .reset : nil
        default: return nil
        }
    }

    /// Scope and offset, plus Reset only under This Title: with All Titles
    /// there is no title offset to reset (Benjamin, 2026-10-18).
    static func offsetRowCount(_ context: TVPlayerContext) -> Int {
        guard let offset = context.audioOffset else { return 0 }
        return offset.scope == .thisTitle ? 3 : 2
    }

    // MARK: Audio tab columns

    // Two columns (Benjamin, 2026-10-18): the tracks on the left, and on the
    // right the scope, offset and Reset rows, numbered on from the tracks.
    // Up/Down stay in a column; Right from a track goes to the offset row;
    // Left from the scope or Reset row comes back to the chosen track; on the
    // offset row Left/Right step it.

    /// Reset takes focus only while the title has its own offset.
    static func isFocusable(_ row: TVAudioPanelRow?, _ context: TVPlayerContext) -> Bool {
        guard row == .reset else { return row != nil }
        return context.audioOffset?.hasTitleOffset == true
    }

    static func audioUp(from index: Int, _ context: TVPlayerContext) -> TVPlayerInputState.Panel.Focus {
        let tracks = context.audioTrackIDs.count
        switch audioRow(at: index, context) {
        case .track(let track): return track > 0 ? .content(track - 1) : .tabs
        case .scope, nil: return .tabs
        case .offset: return .content(tracks)
        case .reset: return .content(tracks + 1)
        }
    }

    static func audioDown(from index: Int, _ context: TVPlayerContext) -> TVPlayerInputState.Panel.Focus {
        let row = audioRow(at: index, context)
        if case .track(let track) = row {
            return .content(track + 1 < context.audioTrackIDs.count ? track + 1 : track)
        }
        let next = index + 1
        return isFocusable(audioRow(at: next, context), context) ? .content(next) : .content(index)
    }

    /// Where an arrow leaves focus on the Audio tab, and what it does.
    static func audioArrow(
        _ direction: TVDirection, at index: Int, _ context: TVPlayerContext
    ) -> (focus: TVPlayerInputState.Panel.Focus, commands: [TVPlayerCommand]) {
        let tracks = context.audioTrackIDs.count
        let chosenTrack = TVPlayerInputState.Panel.Focus.content(min(context.selectedAudioIndex ?? 0, max(tracks - 1, 0)))
        switch audioRow(at: index, context) {
        case .track:
            guard direction == .right, context.audioOffset != nil else { return (.content(index), []) }
            return (.content(tracks + 1), [])
        case .scope, .reset:
            return direction == .left && tracks > 0 ? (chosenTrack, []) : (.content(index), [])
        case .offset:
            return (.content(index), offsetStep(direction, context))
        case nil:
            return (.content(index), [])
        }
    }

    /// A step of the offset row, or nothing at its limit.
    static func offsetStep(_ direction: TVDirection, _ context: TVPlayerContext) -> [TVPlayerCommand] {
        guard let offset = context.audioOffset else { return [] }
        let up = direction == .right
        return (up ? offset.canIncrease : offset.canDecrease) ? [.stepAudioOffset(up ? 1 : -1)] : []
    }

    /// Where Down lands: Restart, the current chapter, the chosen track (Off
    /// is Subtitles' row 0).
    static func defaultIndex(_ tab: TVPanelTab, _ context: TVPlayerContext) -> Int {
        switch tab {
        case .info: 0
        case .chapters: context.chapterStarts.lastIndex { $0 <= context.currentTime } ?? 0
        case .audio: context.selectedAudioIndex ?? 0
        case .subtitles: context.selectedSubtitleIndex.map { $0 + 1 } ?? 0
        }
    }

    /// A row's action, and whether it closes the panel: Restart and a
    /// chapter play from there and close; a track switch stays, so the
    /// change can be seen or heard.
    static func activateRow(
        _ tab: TVPanelTab, _ index: Int, _ context: TVPlayerContext
    ) -> (commands: [TVPlayerCommand], closesPanel: Bool) {
        switch tab {
        case .info:
            return ([.seek(0), .play], true)
        case .chapters:
            guard context.chapterStarts.indices.contains(index) else { return ([], false) }
            return ([.seek(context.chapterStarts[index]), .play], true)
        case .audio:
            switch audioRow(at: index, context) {
            case .track(let track):
                return ([.selectAudio(id: context.audioTrackIDs[track])], false)
            case .scope:
                let scope: AudioOffsetScope = context.audioOffset?.scope == .thisTitle ? .allTitles : .thisTitle
                return ([.setAudioOffsetScope(scope)], false)
            case .reset:
                return context.audioOffset?.hasTitleOffset == true ? ([.resetAudioOffset], false) : ([], false)
            case .offset, nil:
                return ([], false)
            }
        case .subtitles:
            if index == 0 { return ([.selectSubtitle(id: nil)], false) }
            guard context.subtitleTrackIDs.indices.contains(index - 1) else { return ([], false) }
            return ([.selectSubtitle(id: context.subtitleTrackIDs[index - 1])], false)
        }
    }
}
