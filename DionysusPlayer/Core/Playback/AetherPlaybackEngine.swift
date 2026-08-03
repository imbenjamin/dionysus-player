import Combine
import CoreMedia
import Foundation
import SwiftUI
import AetherEngine

/// `PlaybackEngine` implemented on top of AetherEngine.
///
/// Written against AetherEngine's published guides/docs rather than against
/// the compiler (no macOS/Xcode toolchain was available while scaffolding
/// this project), so some of the bridging below is intentionally defensive:
///
/// - The core calls (`load`, `play`, `pause`, `togglePlayPause`, `stop`,
///   `seek`, `selectAudioTrack`, `selectSubtitleTrack`,
///   `AetherPlayerSurface(engine:)`) are taken verbatim from AetherEngine's
///   documented API and should just work.
/// - `state`/`clock.currentTime`/track metadata are bridged loosely (string
///   matching, `Mirror` reflection) because their exact case names / stored
///   property names weren't confirmed. If AetherEngine's real shape differs,
///   this is the one file that needs adjusting — everything else in the app
///   only talks to the `PlaybackEngine` protocol.
@MainActor
final class AetherPlaybackEngine: PlaybackEngine {
    private let player = AetherPlayer()
    private var cancellables: Set<AnyCancellable> = []

    var onStateChange: ((PlaybackState) -> Void)?
    var onTimeUpdate: ((TimeInterval, TimeInterval) -> Void)?

    private(set) var audioTracks: [PlaybackTrack] = []
    private(set) var subtitleTracks: [PlaybackTrack] = []
    private(set) var videoFormatDescription: String?

    private var selectedAudioTrackID: Int?
    private var selectedSubtitleTrackID: Int?

    init() {
        observePlayer()
    }

    private func observePlayer() {
        player.$state
            .sink { [weak self] state in
                self?.onStateChange?(Self.bridgeState(state))
            }
            .store(in: &cancellables)

        player.clock.$currentTime
            .sink { [weak self] time in
                guard let self else { return }
                self.onTimeUpdate?(Self.seconds(from: time), Self.seconds(from: self.player.duration))
            }
            .store(in: &cancellables)

        player.$videoFormat
            .sink { [weak self] format in
                self?.videoFormatDescription = Self.describeFormat(format)
            }
            .store(in: &cancellables)
    }

    func load(url: URL) async throws {
        try await player.load(url: url)
        audioTracks = Self.normalizeTracks(player.audioTracks, kind: .audio, selectedID: selectedAudioTrackID)
        subtitleTracks = Self.normalizeTracks(player.subtitleTracks, kind: .subtitle, selectedID: selectedSubtitleTrackID)
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func togglePlayPause() { player.togglePlayPause() }
    func stop() { player.stop() }

    func seek(to time: TimeInterval) async {
        await player.seek(to: time)
    }

    func selectAudioTrack(id: Int) {
        player.selectAudioTrack(index: id)
        selectedAudioTrackID = id
        audioTracks = audioTracks.map { PlaybackTrack(id: $0.id, kind: $0.kind, displayTitle: $0.displayTitle, isSelected: $0.id == id) }
    }

    func selectSubtitleTrack(id: Int?) {
        selectedSubtitleTrackID = id
        if let id {
            player.selectSubtitleTrack(index: id)
        }
        subtitleTracks = subtitleTracks.map { PlaybackTrack(id: $0.id, kind: $0.kind, displayTitle: $0.displayTitle, isSelected: $0.id == id) }
    }

    func makeSurface() -> AnyView {
        AnyView(AetherPlayerSurface(engine: player))
    }

    // MARK: - Defensive bridging

    private static func bridgeState(_ aetherState: Any) -> PlaybackState {
        let description = String(describing: aetherState).lowercased()
        if description.contains("error") { return .failed(description) }
        if description.contains("play") { return .playing }
        if description.contains("pause") { return .paused }
        if description.contains("seek") { return .seeking }
        if description.contains("end") { return .ended }
        if description.contains("load") { return .loading }
        return .idle
    }

    private static func seconds(from value: Any) -> TimeInterval {
        if let interval = value as? TimeInterval { return interval }
        if let cmTime = value as? CMTime { return CMTimeGetSeconds(cmTime) }
        return 0
    }

    private static func describeFormat(_ value: Any?) -> String? {
        guard let value else { return nil }
        let description = String(describing: value)
        return description.isEmpty || description == "nil" ? nil : description
    }

    /// Reads a track's display title via reflection, since the concrete
    /// audio/subtitle track struct's field names weren't confirmed.
    private static func normalizeTracks(_ tracks: [Any], kind: PlaybackTrack.Kind, selectedID: Int?) -> [PlaybackTrack] {
        tracks.enumerated().map { index, track in
            PlaybackTrack(
                id: index,
                kind: kind,
                displayTitle: displayTitle(for: track, fallbackIndex: index),
                isSelected: selectedID == index
            )
        }
    }

    private static func displayTitle(for track: Any, fallbackIndex: Int) -> String {
        let mirror = Mirror(reflecting: track)
        for label in ["displayTitle", "title", "name"] {
            if let value = mirror.children.first(where: { $0.label == label })?.value as? String, !value.isEmpty {
                return value
            }
        }
        if let language = mirror.children.first(where: { $0.label == "language" || $0.label == "languageCode" })?.value as? String,
           !language.isEmpty {
            return language
        }
        return "Track \(fallbackIndex + 1)"
    }
}
