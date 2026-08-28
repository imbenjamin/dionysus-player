import Foundation

/// Jellyfin's `DeviceProfile` schema and the pieces it's built from — sent
/// on `/PlaybackInfo` only in "Allow Transcoding" mode (see
/// `StreamPreferenceStore`) so the server can negotiate direct play/direct
/// stream/transcode instead of the app always hand-building a `Static=true`
/// stream URL. Own file, not folded into `JellyfinModels.swift`, for the
/// same reason `DownloadTypes.swift` got its own file: a sizeable,
/// self-contained schema with its own construction logic
/// (`DeviceProfileBuilder` below).
///
/// `JellyfinJSON`'s encoder only flips the first character's case
/// (camelCase ↔ PascalCase, see `JellyfinCoding.swift`), so none of these
/// need `CodingKeys` — including `TranscodingProfile.protocol` below, whose
/// backticks are pure Swift-keyword escaping and don't affect the derived
/// JSON key (`"protocol"` → `"Protocol"`).

struct ProfileCondition: Codable, Equatable {
    /// "Equals" | "NotEquals" | "LessThanEqual" | "GreaterThanEqual" | "EqualsAny"
    var condition: String
    /// e.g. "VideoCodecTag", "VideoBitDepth", "AudioChannels".
    var property: String
    var value: String
    var isRequired: Bool
}

struct DirectPlayProfile: Codable, Equatable {
    /// CSV.
    var container: String
    /// "Video" | "Audio" | "Photo"
    var type: String
    /// CSV.
    var videoCodec: String?
    /// CSV.
    var audioCodec: String?
}

struct TranscodingProfile: Codable, Equatable {
    var container: String
    var type: String
    var videoCodec: String?
    var audioCodec: String?
    /// "http" | "hls" — backtick-escaped because `protocol` is a Swift
    /// keyword; see this file's header comment for why that doesn't affect
    /// the wire format.
    var `protocol`: String
    /// "Streaming" | "Static"
    var context: String
    var enableSubtitlesInManifest: Bool
    var maxAudioChannels: String?
    var minSegments: Int?
    var breakOnNonKeyFrames: Bool?
    var conditions: [ProfileCondition]?
}

struct CodecProfile: Codable, Equatable {
    /// "Video" | "VideoAudio" | "Audio"
    var type: String
    /// CSV.
    var codec: String?
    var conditions: [ProfileCondition]?
    var applyConditions: [ProfileCondition]?
}

struct SubtitleProfile: Codable, Equatable {
    /// "srt", "ass", "ssa", "vtt", "pgssub", ...
    var format: String
    /// "Embed" | "External" | "Hls" | "Encode" | "Drop"
    var method: String
}

struct DeviceProfile: Codable, Equatable {
    var maxStreamingBitrate: Int?
    var maxStaticBitrate: Int?
    var musicStreamingTranscodingBitrate: Int?
    var maxStaticMusicBitrate: Int?
    var directPlayProfiles: [DirectPlayProfile]
    var transcodingProfiles: [TranscodingProfile]
    var codecProfiles: [CodecProfile]
    var subtitleProfiles: [SubtitleProfile]
    // ContainerProfiles / ResponseProfiles deliberately omitted — Jellyfin
    // defaults to empty server-side when the key is absent, and neither is
    // needed for the codec/container/subtitle decisions this app cares about.
}

/// Hand-authored from AetherEngine's documented decode matrix
/// (`AetherEngine/docs/formats.md`) — there's no runtime capability-query
/// API to derive this from (only `AetherEngine.displayCapabilities`, which
/// covers *display* HDR support, not decode support, and isn't called
/// anywhere in this app today).
///
/// Two distinct capability sets are encoded here, and must not be
/// conflated: `directPlayProfiles`/`codecProfiles` describe what
/// AetherEngine itself can decode (FFmpeg-backed — broad), while
/// `transcodingProfiles` describes what the server should encode *to* when
/// it can't direct play. Because a server transcode is consumed via
/// AetherEngine's `nativeRemoteHLS` bypass — the playlist goes straight to
/// AVPlayer, no FFmpeg decode step in between — the transcoding profile is
/// restricted to what AVPlayer decodes natively, not AetherEngine's broader
/// matrix. Per `CLAUDE.md`, only H.264/HEVC video + EAC3 audio (+
/// HDR10/HDR10+/DoVi) is confirmed on a physical device, so that's the set
/// offered for transcode targets.
enum DeviceProfileBuilder {
    /// 120 Mbps — comfortably above any real-world Blu-ray-remux bitrate,
    /// so direct play/stream eligibility is never bitrate-gated by this
    /// client. See `build(maxStreamingBitrate:)`'s doc comment on
    /// `maxStaticBitrate` for why this must stay independent of the user's
    /// `StreamingMaxBitrate` setting.
    private static let staticBitrateCeiling = 120_000_000

    static func build(maxStreamingBitrate: Int?) -> DeviceProfile {
        let directPlayVideo = DirectPlayProfile(
            container: "mp4,m4v,mkv,mov,webm,ts,mpegts,m2ts,avi,ogg,flv",
            type: "Video",
            videoCodec: "h264,hevc,av1,vp9,vp8,mpeg4,mpeg2video,vc1,wmv2,wmv3,mjpeg",
            audioCodec: "aac,ac3,eac3,flac,alac,truehd,dts,mp3,opus,vorbis,pcm_s16le,pcm_s24le"
        )
        let directPlayAudio = DirectPlayProfile(
            container: "mp3,aac,flac,alac,ogg,wma,wav",
            type: "Audio", videoCodec: nil,
            audioCodec: "aac,mp3,flac,alac,vorbis,opus,wmav2,pcm_s16le"
        )

        // No HEVC `VideoCodecTag` gate here — deliberately removed
        // (2026-08-28) despite being a real thing in reference clients
        // (Swiftfin requires `hvc1`/`dvh1`, rejecting the common `hev1`
        // tag): that restriction exists because AVPlayer mishandles
        // `hev1`'s B-frame reordering, but AetherEngine's direct-play
        // route (`streamURL`, used regardless of streaming mode) never
        // touches AVPlayer — it decodes via its own FFmpeg pipeline, which
        // isn't tag-sensitive the same way. Confirmed live: a `hev1`-tagged
        // x265 source was needlessly forced to transcode
        // (`VideoCodecTagNotSupported`) under the borrowed restriction.
        // AVPlayer *does* enter the picture on the transcode-consumption
        // route (`nativeRemoteHLS`), but that's a question about
        // Jellyfin's own transcode *output* tagging, not this gate on the
        // *source*.

        // `videoCodec: "h264"` only — deliberately narrower than the
        // direct-play matrix above. Confirmed live (2026-08-28): when
        // Jellyfin picked HEVC as the transcode target for this exact
        // profile (still `nativeRemoteHLS`-delivered, so no local FFmpeg
        // decode either way), playback showed `Playing`/advancing position
        // with a completely black screen and no audio — H.264 transcode
        // targets, tried moments earlier on the same device/content,
        // rendered correctly. This is a different pipeline question from
        // "can AetherEngine direct-play HEVC" (yes, confirmed elsewhere in
        // CLAUDE.md) — it's specifically about consuming an HEVC-coded HLS
        // stream through this bypass, which doesn't work yet. Revisit
        // (and re-add "hevc" here) only after that's independently
        // confirmed fixed/working on a real device.
        let hlsTranscode = TranscodingProfile(
            container: "ts", type: "Video", videoCodec: "h264", audioCodec: "aac,ac3,eac3",
            protocol: "hls", context: "Streaming", enableSubtitlesInManifest: true,
            maxAudioChannels: "6", minSegments: 1, breakOnNonKeyFrames: true, conditions: nil
        )

        let subtitleProfiles = [
            // Bitmap-only formats — must be Embed, never External (External
            // only works for text formats the server can proxy as-is).
            SubtitleProfile(format: "pgssub", method: "Embed"),
            SubtitleProfile(format: "dvdsub", method: "Embed"),
            SubtitleProfile(format: "dvbsub", method: "Embed"),
            // Text formats — External, matching the existing `subtitleURL` behavior.
            SubtitleProfile(format: "srt", method: "External"),
            SubtitleProfile(format: "ass", method: "External"),
            SubtitleProfile(format: "ssa", method: "External"),
            SubtitleProfile(format: "vtt", method: "External")
        ]

        // `nil` normally means "no user-imposed cap" (the "Unlimited"
        // `StreamingMaxBitrate` setting) — but omitting the JSON key
        // entirely does NOT mean "no limit" to Jellyfin. Confirmed live
        // (2026-08-28, server-side debug log against a real request):
        // Jellyfin's own `DeviceProfile.MaxStreamingBitrate` model property
        // defaults an absent value to a hardcoded 8 Mbps server-side — and
        // this is the field that actually governs direct-play/stream
        // eligibility here, not `MaxStaticBitrate` below: Jellyfin's
        // `/PlaybackInfo` handler hardcodes `Context =
        // EncodingContext.Streaming` for this whole check, so — contrary
        // to what the field names suggest — `MaxStaticBitrate` is never
        // even consulted for eligibility, only `MaxStreamingBitrate` is.
        // A 41 Mbps source was rejected (`ContainerBitrateExceedsLimit`)
        // against that silent 8 Mbps default even with the server's
        // separate "Internet streaming bitrate limit" setting removed
        // entirely and later maxed out — neither touches this field. Must
        // always send an explicit, generous value, same "never omit" fix
        // as `maxStaticBitrate` below.
        let resolvedStreamingBitrate = maxStreamingBitrate ?? Self.staticBitrateCeiling

        return DeviceProfile(
            maxStreamingBitrate: resolvedStreamingBitrate,
            // `MaxStaticBitrate` gates whether a file is even *eligible*
            // for direct play/direct stream in principle (Jellyfin's
            // "Static" context nominally covers both) — kept generous and
            // fixed regardless of the user's transcode-bitrate-cap
            // setting, matching the pattern seen across reference clients,
            // even though (per the above) it turns out not to be what
            // this particular eligibility check reads in practice.
            maxStaticBitrate: Self.staticBitrateCeiling,
            musicStreamingTranscodingBitrate: 384_000,
            maxStaticMusicBitrate: Self.staticBitrateCeiling,
            directPlayProfiles: [directPlayVideo, directPlayAudio],
            transcodingProfiles: [hlsTranscode],
            codecProfiles: [],
            subtitleProfiles: subtitleProfiles
        )
    }
}
