import Foundation

/// The transport's icons, left to right.
enum TVPlayerIcon: CaseIterable, Equatable {
    case chapters, audio, subtitles, stats

    /// Fixed, unlocalized: identifiers and the focus marker use it.
    var id: String {
        switch self {
        case .chapters: "chapters"
        case .audio: "audio"
        case .subtitles: "subtitles"
        case .stats: "stats"
        }
    }
}

/// The swipe-down panel's tabs, left to right. Stats is not one: it is a
/// toggle on its icon (Benjamin, 2026-10-06).
enum TVPanelTab: CaseIterable, Equatable {
    case info, chapters, audio, subtitles

    var id: String {
        switch self {
        case .info: "info"
        case .chapters: "chapters"
        case .audio: "audio"
        case .subtitles: "subtitles"
        }
    }

    /// Audio and Subtitles are vertical lists; Chapters is a rail.
    var isList: Bool { self == .audio || self == .subtitles }
}

enum TVDirection: Equatable {
    case left, right

    var sign: Double { self == .left ? -1 : 1 }
    var step: Int { self == .left ? -1 : 1 }
}

enum TVNextUpButton: Equatable {
    case playNow, close
}

/// What the remote did, as the host reports it.
enum TVRemoteInput: Equatable {
    case select, playPause, menu, up, down
    /// Left or Right going down and coming up. The model tells a press
    /// (released within `TVPlayerTiming.holdThreshold`) from a hold.
    case arrowDown(TVDirection), arrowUp(TVDirection)
    /// A horizontal swipe `TVSwipeGate` committed to scrubbing: began, the
    /// travel since it began as a fraction of the surface's width, ended.
    case swipeBegan, swipeMoved(fraction: Double), swipeEnded
    /// One horizontal swipe where no free scrub is possible: it enters or
    /// steps a scan, or moves focus as an arrow press would.
    case swipeStep(TVDirection)
    /// The model's clock. Holds, scans, fades and timeouts advance on it.
    case tick
}

/// What the host must do to the player (`TVPlayerCommandRunner`).
enum TVPlayerCommand: Equatable {
    case play, pause, togglePlayPause
    case seek(TimeInterval)
    case skipSegment(id: String)
    case playNext, dismissNextUp
    case selectAudio(id: Int), selectSubtitle(id: Int?)
    case close
}

/// The facts the model reads but never sets, snapshotted from
/// `PlayerViewModel` and the settings on every input
/// (`TVPlayerContext.init(viewModel:defaults:)`).
struct TVPlayerContext: Equatable {
    enum Playback: Equatable {
        case loading, playing, paused, ended, failed

        /// Nothing to act on while a title loads or after it failed: only
        /// Menu does anything then, and it closes the player.
        var acceptsInput: Bool { self != .loading && self != .failed }
    }

    struct SkipSegment: Equatable {
        var id: String
        var endSeconds: TimeInterval
    }

    var playback: Playback = .playing
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var chapterStarts: [TimeInterval] = []
    var audioTrackIDs: [Int] = []
    var selectedAudioIndex: Int?
    var subtitleTrackIDs: [Int] = []
    /// `nil` while subtitles are off.
    var selectedSubtitleIndex: Int?
    var statsButtonEnabled = false
    var chaptersInScrubber = true
    var skipSegment: SkipSegment?
    var nextUpSecondsRemaining: Int?
    var closesWhenPlaybackEnds = true
    /// The UI-test harness's `-UITestDisableControlAutoHide`.
    var autoHideDisabled = false

    /// The icons with something to do, so none is a dead stop.
    var availableIcons: [TVPlayerIcon] {
        TVPlayerIcon.allCases.filter { icon in
            switch icon {
            case .chapters: !chapterStarts.isEmpty
            case .audio: audioTrackIDs.count > 1
            case .subtitles: !subtitleTrackIDs.isEmpty
            case .stats: statsButtonEnabled
            }
        }
    }
}

/// Everything the player's UI is doing. The overlay draws from it; only the
/// reducer changes it.
struct TVPlayerInputState: Equatable {
    enum Chrome: Equatable { case hidden, transport }
    /// `skip` and `nextUp` are the bottom-right slot's Skip button and Next
    /// Up card, each its own stop above the icon row while the transport is
    /// up (Benjamin, 2026-10-07). Only one shows at a time.
    enum TransportFocus: Equatable { case scrubber, icon(TVPlayerIcon), skip, nextUp }

    struct HeldArrow: Equatable {
        var direction: TVDirection
        var pressedAt: TimeInterval
        var isHold = false
        /// The hold entered or stepped a scan, so its release does nothing.
        var actedAsScan = false
    }

    /// Native-style scanning (Benjamin, 2026-10-06): a level from -4 to 4,
    /// 0 holding the preview still. The picture stays paused; only the
    /// trickplay preview moves.
    struct Scan: Equatable {
        var level: Int
        var lastTickAt: TimeInterval
    }

    /// The glyph flashed mid-screen to confirm an action.
    struct Flash: Equatable {
        enum Kind: Equatable { case play, pause, skipBack, skipForward }
        var kind: Kind
        /// New for every action, so a repeat flashes again.
        var serial: Int
    }

    /// A scrub moves a preview, never playback, until it is committed.
    struct Scrub: Equatable {
        var previewTime: TimeInterval
        /// Whether the scrub paused playback, so cancelling resumes it.
        var resumesOnCancel: Bool
        /// The preview when the current swipe began.
        var swipeAnchor: TimeInterval?
        var scan: Scan?
    }

    /// The swipe-down panel: which tab, and whether focus is on the tabs or
    /// on a row of the tab's content.
    struct Panel: Equatable {
        enum Focus: Equatable { case tabs, content(Int) }
        var tab: TVPanelTab
        var focus: Focus
        var lastInputAt: TimeInterval
    }

    var chrome: Chrome = .transport
    var transportFocus: TransportFocus = .scrubber
    var lastInputAt: TimeInterval = 0
    var heldArrow: HeldArrow?
    var scrub: Scrub?
    var panel: Panel?
    var isStatsOn = false
    /// A skip button Menu hid while nothing else was up. It shows again with
    /// the transport (Benjamin, 2026-10-06).
    var hiddenSkipSegmentID: String?
    var nextUpFocus: TVNextUpButton = .playNow
    var hasRequestedAdvance = false
    var hasRequestedClose = false
    var flash: Flash?
}

/// The spec's timings (Benjamin, 2026-10-06), tuned against Infuse on the
/// Bedroom Apple TV (2026-10-08).
enum TVPlayerTiming {
    static let chromeFade: TimeInterval = 4
    static let holdThreshold: TimeInterval = 0.4
    static let skipInterval: TimeInterval = 10
    /// The panel closes after this long without a press.
    static let panelTimeout: TimeInterval = 10
    /// Real-time multiples for scan levels 1 to 4. The native transport (as
    /// Infuse uses it) has four levels, its third about our 64x and its fourth
    /// faster (Benjamin, Bedroom Apple TV, 2026-10-08). Its count is the
    /// highest level.
    static let scanRates: [Double] = [8, 32, 64, 128]
}

/// How a swipe maps onto the title.
enum TVScrubMetrics {
    /// A swipe across the whole surface covers this fraction of the title.
    /// The native transport (Infuse) scales with length: ~5 min of a 119-min
    /// film, 35s of a 9:22 episode (Bedroom Apple TV, 2026-10-08).
    static let fullSwipeFractionOfDuration = 0.05
    /// A swipe's preview snaps to a chapter start this close, as a fraction
    /// of the title (43s of a 90-minute film).
    static let snapFractionOfDuration = 0.008
}

/// The player's remote as a pure reducer: a state, an input and a snapshot
/// of the player in; the new state and the commands for the host out.
///
/// The tvOS focus engine is not used in the player (Sodalite's approach):
/// the host's recognizers take every press and this decides what it means,
/// so a press can never land somewhere the focus engine chose instead.
enum TVPlayerInputModel {
    /// What an input means once a press has been told from a hold.
    enum Intent: Equatable {
        case select, playPause, menu, up, down
        case arrow(TVDirection)
        case holdBegan(TVDirection)
        case swipeBegan, swipeMoved(Double), swipeEnded
        case swipeStep(TVDirection)
    }

    static func reduce(
        _ state: inout TVPlayerInputState, _ input: TVRemoteInput, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        if input == .tick { return tick(&state, context: context, now: now) }
        guard context.playback.acceptsInput else {
            state.heldArrow = nil
            guard input == .menu else { return [] }
            // An audio switch rebuilds the session, reading as loading with
            // the Audio tab still open: Menu closes the tab first (M4 review).
            if state.panel != nil {
                state.panel = nil
                return []
            }
            return [.close]
        }
        state.lastInputAt = now
        state.panel?.lastInputAt = now
        let intent: Intent
        switch input {
        case .select: intent = .select
        case .playPause: intent = .playPause
        case .menu: intent = .menu
        case .up: intent = .up
        case .down: intent = .down
        case .arrowDown(let direction):
            state.heldArrow = .init(direction: direction, pressedAt: now)
            return []
        case .arrowUp(let direction):
            guard let held = state.heldArrow, held.direction == direction else { return [] }
            state.heldArrow = nil
            // A hold that entered or stepped a scan has done its work; one
            // that didn't (an icon, the panel) counts as one press.
            if held.actedAsScan { return [] }
            intent = .arrow(direction)
        case .swipeBegan: intent = .swipeBegan
        case .swipeMoved(let fraction): intent = .swipeMoved(fraction)
        case .swipeEnded: intent = .swipeEnded
        case .swipeStep(let direction):
            // Where no scan can start or step, a swipe is an arrow press.
            intent = state.scrub != nil || scrubCanOpen(state, context: context) ? .swipeStep(direction) : .arrow(direction)
        case .tick: return []
        }
        return dispatch(intent, &state, context: context, now: now)
    }

    /// Each concern in turn; the first that handles the intent wins.
    static func dispatch(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        if let commands = reduceScrub(intent, &state, context: context, now: now) { return commands }
        if let commands = reducePanel(intent, &state, context: context) { return commands }
        if let commands = reduceOverlays(intent, &state, context: context) { return commands }
        return reduceTransport(intent, &state, context: context, now: now)
    }

    // MARK: - Transport

    static func reduceTransport(
        _ intent: Intent, _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        let wasHidden = state.chrome == .hidden
        state.chrome = .transport
        switch intent {
        case .select:
            if case .icon(let icon) = state.transportFocus { return activate(icon, &state, context: context, now: now) }
            return togglePlayPause(&state, context: context)
        case .playPause:
            return togglePlayPause(&state, context: context)
        case .menu:
            if state.transportFocus != .scrubber {
                state.transportFocus = .scrubber
                return []
            }
            return [.close]
        case .up:
            guard !wasHidden else { return [] }
            let slot = slotFocus(state, context: context)
            switch state.transportFocus {
            case .scrubber:
                if let first = context.availableIcons.first {
                    state.transportFocus = .icon(first)
                } else if let slot {
                    state.transportFocus = slot
                }
            case .icon:
                if let slot { state.transportFocus = slot }
            case .skip, .nextUp:
                break
            }
            return []
        case .down:
            switch state.transportFocus {
            case .icon:
                state.transportFocus = .scrubber
            case .skip, .nextUp:
                // The rightmost icon sits beneath the slot.
                state.transportFocus = context.availableIcons.last.map { .icon($0) } ?? .scrubber
            case .scrubber:
                openPanel(.info, focus: .tabs, &state, now: now)
            }
            return []
        case .arrow(let direction):
            if state.transportFocus == .skip || state.transportFocus == .nextUp { return [] }
            if case .icon(let icon) = state.transportFocus {
                state.transportFocus = .icon(neighbour(of: icon, direction, in: context.availableIcons))
                return []
            }
            let commands = skip(direction, context: context)
            if !commands.isEmpty { flash(direction == .left ? .skipBack : .skipForward, &state) }
            return commands
        case .holdBegan, .swipeBegan, .swipeMoved, .swipeEnded, .swipeStep:
            return []
        }
    }

    static func activate(
        _ icon: TVPlayerIcon, _ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval
    ) -> [TVPlayerCommand] {
        switch icon {
        case .stats: state.isStatsOn.toggle()
        case .chapters: openPanel(.chapters, focus: .content(defaultIndex(.chapters, context)), &state, now: now)
        case .audio: openPanel(.audio, focus: .content(defaultIndex(.audio, context)), &state, now: now)
        case .subtitles: openPanel(.subtitles, focus: .content(defaultIndex(.subtitles, context)), &state, now: now)
        }
        return []
    }

    static func togglePlayPause(_ state: inout TVPlayerInputState, context: TVPlayerContext) -> [TVPlayerCommand] {
        guard context.playback != .ended else { return [] }
        flash(context.playback == .playing ? .pause : .play, &state)
        return [.togglePlayPause]
    }

    static func flash(_ kind: TVPlayerInputState.Flash.Kind, _ state: inout TVPlayerInputState) {
        state.flash = .init(kind: kind, serial: (state.flash?.serial ?? 0) + 1)
    }

    /// The scrubber shows its knob while it has focus: transport up, no icon
    /// focused, no panel.
    static func scrubberHasFocus(_ state: TVPlayerInputState) -> Bool {
        state.chrome == .transport && state.transportFocus == .scrubber && state.panel == nil
    }

    static func neighbour(of icon: TVPlayerIcon, _ direction: TVDirection, in icons: [TVPlayerIcon]) -> TVPlayerIcon {
        guard let index = icons.firstIndex(of: icon) else { return icons.first ?? icon }
        let next = index + (direction == .left ? -1 : 1)
        return icons.indices.contains(next) ? icons[next] : icon
    }

    /// Review Focus 1: no duration, no seek. M1's `skip(by:)` seeked to 0.
    static func skip(_ direction: TVDirection, context: TVPlayerContext) -> [TVPlayerCommand] {
        guard context.duration > 0 else { return [] }
        return [.seek(clamp(context.currentTime + direction.sign * TVPlayerTiming.skipInterval, context))]
    }

    static func clamp(_ time: TimeInterval, _ context: TVPlayerContext) -> TimeInterval {
        min(max(time, 0), context.duration)
    }

    // MARK: - Clock

    static func tick(_ state: inout TVPlayerInputState, context: TVPlayerContext, now: TimeInterval) -> [TVPlayerCommand] {
        var commands: [TVPlayerCommand] = []
        if var held = state.heldArrow, !held.isHold, context.playback.acceptsInput,
           now - held.pressedAt >= TVPlayerTiming.holdThreshold {
            held.isHold = true
            state.heldArrow = held
            commands += dispatch(.holdBegan(held.direction), &state, context: context, now: now)
        }
        if var scrub = state.scrub, var scan = scrub.scan {
            let moved = scrub.previewTime + scanRate(level: scan.level) * (now - scan.lastTickAt)
            scrub.previewTime = clamp(moved, context)
            // A scan that reaches either end stops there.
            if moved != scrub.previewTime { scan.level = 0 }
            scan.lastTickAt = now
            scrub.scan = scan
            state.scrub = scrub
        }
        if case .icon(let icon) = state.transportFocus, !context.availableIcons.contains(icon) {
            state.transportFocus = .scrubber
        }
        if state.transportFocus == .skip, !skipButtonVisible(state, context: context) {
            state.transportFocus = .scrubber
        }
        if state.transportFocus == .nextUp, context.nextUpSecondsRemaining == nil {
            state.transportFocus = .scrubber
        }
        if var panel = state.panel {
            if now - panel.lastInputAt >= TVPlayerTiming.panelTimeout {
                state.panel = nil
                state.lastInputAt = now
            } else if case .content(let index) = panel.focus {
                // A list that shrinks under the panel never leaves focus past
                // its end, so a stale row can't pick the wrong track.
                let count = contentCount(panel.tab, context)
                panel.focus = count == 0 ? .tabs : .content(min(index, count - 1))
                state.panel = panel
            }
        }
        switch context.playback {
        case .loading, .paused, .failed:
            // The transport stays up, and its fade waits for playback, so a
            // slow load doesn't use up the title's time on screen.
            state.chrome = .transport
            state.lastInputAt = now
        case .playing, .ended:
            break
        }
        if state.chrome == .transport, chromeMayFade(state, context: context),
           now - state.lastInputAt >= TVPlayerTiming.chromeFade {
            state.chrome = .hidden
            state.transportFocus = .scrubber
        }
        if context.playback == .ended, context.closesWhenPlaybackEnds, !state.hasRequestedClose {
            state.hasRequestedClose = true
            commands.append(.close)
        }
        if context.nextUpSecondsRemaining == nil { state.nextUpFocus = .playNow }
        // Review Focus 2: never under a scrub; once it resolves, once only.
        if context.nextUpSecondsRemaining == 0, state.scrub == nil {
            commands += playNext(&state)
        }
        return commands
    }

    static func chromeMayFade(_ state: TVPlayerInputState, context: TVPlayerContext) -> Bool {
        context.playback == .playing && !context.autoHideDisabled && state.scrub == nil && state.panel == nil
    }
}
