import Foundation

/// Recovers the time libass should render at on a server transcode, where the
/// engine's playhead runs ahead of the picture by an amount that changes with
/// every seek.
///
/// **Why the playhead is wrong there.** A transcode plays Jellyfin's HLS through
/// AVPlayer, and on this route AetherEngine's `sourceTime` is AVPlayer's item
/// time. After a seek Jellyfin restarts its transcode at the source keyframe at
/// or before the requested segment, so that segment's media timestamps begin
/// *earlier* than its slot in the playlist. AVPlayer anchors its item timeline
/// to the first segment it loads after the seek, so item time runs ahead of the
/// picture by that segment's slot minus its keyframe — measured anywhere from
/// 1.1s to 8.3s across the scrubs of one film. It keeps that anchor even when
/// Jellyfin restarts the job again underneath it, so nothing read from the
/// segments themselves recovers it reliably.
///
/// **What does know it.** AVPlayer times the WebVTT rendition AetherEngine
/// injects for the same track (its #316) against the media timestamps rather
/// than the playlist, which is why unstyled subtitles stay in sync on this
/// route. So `AetherPlaybackEngine` keeps that rendition selected, suppresses
/// its drawing, and reports each cue's item time as AVPlayer presents it. A cue
/// whose text matches an event in the script started at that event's `Start`,
/// so `itemTime - Start` is AVPlayer's offset, re-measured on every line.
///
/// **After a seek** the old offset is stale and the new one unknown until the
/// first line starts, so `renderTime(for:)` returns `nil` until then and the
/// overlay paints nothing — a wrong-time line is worse than a missing one for
/// the second or two it lasts. It gives up waiting after
/// `calibrationTimeout` of playback, and renders on the last known offset.
///
/// A plain value type with no clock of its own: every input is an engine time,
/// so tests drive it directly.
struct ASSCueTimingCalibrator {
    /// Largest offset a match may imply. The offset is at most the gap back to
    /// the previous source keyframe (8.3s is the largest seen), so anything
    /// larger is a repeated line matched against the wrong event.
    static let maximumOffset: TimeInterval = 15
    /// How far below zero a match may imply before it is rejected rather than
    /// clamped. Covers WebVTT's millisecond rounding of ASS centiseconds and a
    /// frame of delivery jitter.
    static let negativeTolerance: TimeInterval = 0.25
    /// A line delivered this soon after a reset was already on screen when the
    /// playhead landed. Its delivery time is the landing time, not its start,
    /// so it says nothing about the offset.
    static let carryoverWindow: TimeInterval = 0.5
    /// How long after a reset to keep waiting for a line before rendering on
    /// the last known offset anyway.
    static let calibrationTimeout: TimeInterval = 5
    /// A playhead moving backwards by more than this, or forwards by more than
    /// `forwardJumpThreshold` between two observations, is a seek or a reload
    /// rather than playback.
    static let backwardJumpThreshold: TimeInterval = 0.5
    static let forwardJumpThreshold: TimeInterval = 2

    private enum Phase: Equatable {
        /// Nothing observed yet, so no way to tell a line already on screen
        /// from one just starting.
        case awaitingPlayhead
        /// The playhead jumped to `since`, and no line has started since.
        case awaitingCue(since: TimeInterval)
        /// Rendering on `offset`: measured, or given up waiting for.
        case settled
    }

    private let startsByText: [String: [TimeInterval]]
    private var phase: Phase = .awaitingPlayhead
    /// Item time minus script time. Starts at zero, which is exactly right for
    /// a session that has not seeked since it loaded from the start.
    private(set) var offset: TimeInterval = 0
    private var lastPlayhead: TimeInterval?
    private var previousTexts: Set<String> = []
    /// Lines presented before this item time may have been on screen already,
    /// re-delivered rather than starting. See `carryoverWindow`.
    private var measurableFrom: TimeInterval = 0

    init(script: String) {
        startsByText = Self.dialogueStarts(in: script)
    }

    /// Where libass should render for the engine playhead `sourceTime`, or
    /// `nil` while the offset is unknown and nothing should be painted.
    func renderTime(for sourceTime: TimeInterval) -> TimeInterval? {
        guard phase == .settled else { return nil }
        return sourceTime - offset
    }

    /// Feed every engine playhead tick. Detects seeks and reloads, and ends the
    /// wait for a line after `calibrationTimeout`.
    mutating func observePlayhead(_ time: TimeInterval) {
        defer { lastPlayhead = time }
        if let last = lastPlayhead,
           time < last - Self.backwardJumpThreshold || time > last + Self.forwardJumpThreshold {
            phase = .awaitingCue(since: time)
            previousTexts = []
            measurableFrom = time + Self.carryoverWindow
            return
        }
        switch phase {
        case .awaitingPlayhead:
            phase = .awaitingCue(since: time)
            measurableFrom = time + Self.carryoverWindow
        case .awaitingCue(let since) where time >= since + Self.calibrationTimeout:
            phase = .settled
        default:
            break
        }
    }

    /// AVPlayer is about to re-deliver whatever is on screen as though it had
    /// just started, because its output was (re)attached. Keeps the offset and
    /// keeps rendering on it.
    mutating func ignoreLinesAlreadyShowing() {
        previousTexts = []
        measurableFrom = (lastPlayhead ?? 0) + Self.carryoverWindow
    }

    /// Feed every set of lines AVPlayer presents, with the item time it
    /// presents them at. An empty `texts` is a line ending.
    mutating func observeCues(_ texts: [String], at itemTime: TimeInterval) {
        // Delivered on the same axis as the playhead, and possibly ahead of the
        // tick that would reveal a seek. Checking here first stops a line
        // carried over the seek from being read as one that just started.
        observePlayhead(itemTime)
        let current = Set(texts.map(Self.normalize).filter { !$0.isEmpty })
        defer { previousTexts = current }
        // AVPlayer re-delivers every line still showing whenever a new one
        // starts, and those carry the new line's time, not their own.
        let started = current.subtracting(previousTexts)
        guard !started.isEmpty else { return }
        guard phase != .awaitingPlayhead, itemTime >= measurableFrom else { return }
        // Sorted only so a delivery naming two lines is measured the same way
        // every time.
        for text in started.sorted() {
            guard let measured = measuredOffset(for: text, at: itemTime) else { continue }
            offset = max(0, measured)
            phase = .settled
            return
        }
    }

    /// The offset implied by `text` starting at `itemTime`. A line repeated in
    /// the script ("Yeah.") matches several events; the one closest to the
    /// current offset wins, since the offset changes only at a seek.
    private func measuredOffset(for text: String, at itemTime: TimeInterval) -> TimeInterval? {
        guard let starts = startsByText[text] else { return nil }
        return starts
            .map { itemTime - $0 }
            .filter { $0 >= -Self.negativeTolerance && $0 <= Self.maximumOffset }
            .min { abs($0 - offset) < abs($1 - offset) }
    }

    // MARK: - Script

    /// Every `Dialogue` event's start, keyed by its normalized text.
    static func dialogueStarts(in script: String) -> [String: [TimeInterval]] {
        var starts: [String: [TimeInterval]] = [:]
        var inEvents = false
        // The v4+ default, used until the section's own `Format` line says
        // otherwise. `Text` is always last and may contain commas.
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        for rawLine in script.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
            if key == "format" {
                fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard key == "dialogue",
                  let startIndex = fields.firstIndex(of: "start"),
                  let textIndex = fields.firstIndex(of: "text"), textIndex == fields.count - 1
            else { continue }
            let values = value.split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
            guard values.count == fields.count,
                  let start = parseTime(values[startIndex].trimmingCharacters(in: .whitespaces))
            else { continue }
            let text = normalize(String(values[textIndex]))
            guard !text.isEmpty else { continue }
            starts[text, default: []].append(start)
        }
        return starts
    }

    /// `H:MM:SS.cc`, the only form ASS uses.
    static func parseTime(_ string: String) -> TimeInterval? {
        let parts = string.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Reduces an ASS event's text and the string AVPlayer presents for the
    /// same cue to one comparable form.
    ///
    /// AetherEngine builds the WebVTT by dropping `{...}` override blocks and
    /// turning `\N`, `\n` and `\h` into line breaks and spaces; AVPlayer then
    /// parses that as WebVTT, which consumes `<...>` tags and entities. Applying
    /// all of it to both sides, and ignoring case and whitespace, leaves only the
    /// words.
    static func normalize(_ text: String) -> String {
        var result = ""
        var depth: Character?
        for character in text {
            if let closing = depth {
                if character == closing { depth = nil }
                continue
            }
            switch character {
            case "{": depth = "}"
            case "<": depth = ">"
            default: result.append(character)
            }
        }
        for (escape, replacement) in [
            ("\\N", " "), ("\\n", " "), ("\\h", " "),
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&lrm;", ""), ("&rlm;", ""), ("&amp;", "&"),
        ] {
            result = result.replacingOccurrences(of: escape, with: replacement)
        }
        return result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
