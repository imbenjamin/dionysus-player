import Foundation

/// Jellyfin's `DeviceProfile` schema and its parts, sent on `/PlaybackInfo` in
/// "Allow Transcoding" mode so the server can negotiate direct play, direct
/// stream or transcode rather than the app hand-building a `Static=true` URL.
///
/// `JellyfinJSON`'s encoder only flips the first character's case, so none of
/// these need `CodingKeys` — including `TranscodingProfile.protocol`, whose
/// backticks are Swift keyword escaping and don't reach the JSON key.

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
    /// "http" | "hls". Backtick-escaped as a Swift keyword; see the file header.
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
    // ContainerProfiles and ResponseProfiles are omitted: Jellyfin defaults
    // both to empty, and neither affects the decisions this app cares about.
}

/// Hand-authored from AetherEngine's documented decode matrix
/// (`AetherEngine/docs/formats.md`). There is no runtime capability query to
/// derive it from: `AetherEngine.displayCapabilities` covers display HDR
/// support, not decode.
///
/// Two capability sets live here and must not be conflated.
/// `directPlayProfiles`/`codecProfiles` describe what AetherEngine's
/// FFmpeg-backed pipeline decodes, which is broad. `transcodingProfiles`
/// describes what the server should encode *to*, and a server transcode is
/// consumed through the `nativeRemoteHLS` bypass — straight to AVPlayer, no
/// FFmpeg step — so it is restricted to what AVPlayer decodes natively. Only
/// H.264/HEVC video with EAC3 audio is confirmed on a physical device, so that
/// is the set offered as transcode targets.
enum DeviceProfileBuilder {
    /// Above any real Blu-ray-remux bitrate, so this client never bitrate-gates
    /// direct-play eligibility. Independent of the user's `StreamingMaxBitrate`
    /// setting — see `build(maxStreamingBitrate:)`.
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

        // No HEVC `VideoCodecTag` gate, despite reference clients requiring
        // `hvc1`/`dvh1` and rejecting the common `hev1`. That restriction
        // exists because AVPlayer mishandles `hev1`'s B-frame reordering, but
        // the direct-play route never touches AVPlayer — it decodes through
        // FFmpeg, which isn't tag-sensitive — so the borrowed restriction just
        // forced `hev1`-tagged x265 sources to transcode. AVPlayer does serve
        // the transcode-consumption route, but that concerns Jellyfin's output
        // tagging rather than this gate on the source.

        // Fragmented MP4, not MPEG-TS, carrying both H.264 and HEVC. Per
        // Apple's HLS Authoring Specification AVPlayer supports HEVC only over
        // fMP4 carriage; HEVC-in-MPEG-TS is a combination it decodes no video
        // for, which presents as a black screen with no audio while the session
        // reports itself playing. Jellyfin's own web client likewise offers HEVC
        // over `"ts"` only to Tizen/webOS/Vidaa, which have TS-HEVC hardware
        // decoders AVPlayer lacks; every native-fMP4-HLS platform gets HEVC
        // through a `Container: 'mp4'` profile.
        //
        // AetherEngine ships a recovery for this — a load-time probe that
        // detects a finite HEVC-in-MPEG-TS VOD playlist and reroutes from
        // `.remoteBypass` to its own TS-to-fMP4 remux — but it fails open for a
        // still-encoding playlist with no `ENDLIST`. Requesting the right
        // container avoids depending on it and keeps the session on a clean
        // `.remoteBypass`, visible in the stats overlay's `route` row. H.264
        // shares the profile rather than keeping a separate `"ts"` one.
        let hlsTranscode = TranscodingProfile(
            container: "mp4", type: "Video", videoCodec: "h264,hevc", audioCodec: "aac,ac3,eac3",
            protocol: "hls", context: "Streaming", enableSubtitlesInManifest: true,
            maxAudioChannels: "6", minSegments: 1, breakOnNonKeyFrames: true, conditions: nil
        )

        let subtitleProfiles = [
            // Bitmap formats must be Embed: External only works for text
            // formats the server can proxy as-is.
            SubtitleProfile(format: "pgssub", method: "Embed"),
            SubtitleProfile(format: "dvdsub", method: "Embed"),
            SubtitleProfile(format: "dvbsub", method: "Embed"),
            // Text formats are External, matching `subtitleURL`.
            SubtitleProfile(format: "srt", method: "External"),
            SubtitleProfile(format: "ass", method: "External"),
            SubtitleProfile(format: "ssa", method: "External"),
            SubtitleProfile(format: "vtt", method: "External")
        ]

        // A `nil` here means no user-imposed cap, but omitting the JSON key
        // does not mean "no limit" to Jellyfin: an absent
        // `DeviceProfile.MaxStreamingBitrate` defaults to a hardcoded 8 Mbps
        // server-side. That is the field governing direct-play eligibility, not
        // `MaxStaticBitrate` — `/PlaybackInfo` hardcodes
        // `Context = EncodingContext.Streaming` for the whole check, so despite
        // the names only `MaxStreamingBitrate` is consulted. A 41 Mbps source is
        // rejected as `ContainerBitrateExceedsLimit` against that silent
        // default, regardless of the server's own streaming-bitrate setting. So
        // always send an explicit, generous value.
        let resolvedStreamingBitrate = maxStreamingBitrate ?? Self.staticBitrateCeiling

        return DeviceProfile(
            maxStreamingBitrate: resolvedStreamingBitrate,
            // Nominally gates direct-play eligibility, though per the above it
            // isn't what the check actually reads. Kept generous and fixed
            // regardless of the user's bitrate cap, as reference clients do.
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
