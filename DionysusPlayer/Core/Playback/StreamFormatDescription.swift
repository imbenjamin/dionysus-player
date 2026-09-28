import AetherEngine

/// The stream-format rows of `PlaybackStatsOverlay`: codec, pixel format,
/// colour description and audio sampling, formatted once for two sources that
/// speak the same vocabulary.
///
/// AetherEngine's probe (`sourceVideoStreamFormat`, `TrackInfo`, 7.21.0) and
/// Jellyfin's `MediaStream` both report libav's names: "hevc", "Main 10",
/// "yuv420p10le", "bt2020", "smpte2084", "bt2020nc". The engine's probe never
/// runs on a server transcode (`.remoteBypass`), so the overlay falls back to
/// Jellyfin's probe of the same file there, and formatting both through here
/// makes a row read the same whichever source filled it.
///
/// The colour names go through AetherEngine's own `VideoStreamFormat` labels
/// rather than a second copy of its table. Like `AetherEngineVersion`, this
/// exists so feature code can use them without importing the engine.
enum StreamFormatDescription {
    /// "HEVC Main 10". The profile is left off when undeclared.
    static func codec(name: String?, profile: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let codec = codecLabel(name)
        guard let profile, !profile.isEmpty else { return codec }
        return "\(codec) \(profile)"
    }

    /// "yuv420p10le (10-bit)". The depth alone when the pixel format is
    /// unknown, which is how libav reports a stream it had no decoder for.
    static func pixelFormat(name: String?, bitDepth: Int?) -> String? {
        let depth = bitDepth.flatMap { $0 > 0 ? "\($0)-bit" : nil }
        switch (name, depth) {
        case let (name?, depth?): return "\(name) (\(depth))"
        case let (name?, nil): return name
        case let (nil, depth?): return depth
        case (nil, nil): return nil
        }
    }

    /// "BT.2020 · PQ (SMPTE ST 2084) · BT.2020 NCL · Limited": primaries,
    /// transfer, matrix, range, in that order. A field the stream leaves
    /// unspecified is omitted, not reported as BT.709 — an untagged SDR file
    /// reads "—" rather than claiming a colour space it never declared.
    static func color(primaries: String?, transfer: String?, matrix: String?, range: String?) -> String? {
        let format = VideoStreamFormat(
            pixelFormat: nil, bitDepth: nil, colorPrimaries: primaries,
            transfer: transfer, matrix: matrix, range: range, profile: nil
        )
        let parts = [format.colorPrimariesLabel, format.transferLabel, format.matrixLabel, format.rangeLabel]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "48 kHz · 24-bit". The depth is left off when it is 0 or missing:
    /// AAC, AC-3, E-AC-3 and Opus decode to float and have no fixed depth.
    static func audioSampling(sampleRate: Int?, bitsPerSample: Int?) -> String? {
        var parts: [String] = []
        if let sampleRate, sampleRate > 0 {
            parts.append(sampleRateLabel(sampleRate))
        }
        if let bitsPerSample, bitsPerSample > 0 {
            parts.append("\(bitsPerSample)-bit")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Matroska" for libav's "matroska,webm". libav names a demuxer by every
    /// format it accepts, so the common ones are spelled out and anything else
    /// passes through as libav wrote it.
    static func container(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        switch name {
        case "matroska,webm": return "Matroska"
        case "mov,mp4,m4a,3gp,3g2,mj2": return "MP4"
        case "mpegts": return "MPEG-TS"
        case "hls": return "HLS"
        case "avi": return "AVI"
        default: return name
        }
    }

    /// A codec name in libavcodec's spelling, as a viewer reads it. Unknown
    /// codecs pass through uppercased.
    static func codecLabel(_ name: String) -> String {
        switch name {
        case "hevc": return "HEVC"
        case "h264": return "H.264"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "vp8": return "VP8"
        case "mpeg2video": return "MPEG-2"
        case "mpeg4": return "MPEG-4"
        case "vc1": return "VC-1"
        default: return name.uppercased()
        }
    }

    private static func sampleRateLabel(_ hertz: Int) -> String {
        if hertz % 1000 == 0 { return "\(hertz / 1000) kHz" }
        return String(format: "%.1f kHz", Double(hertz) / 1000)
    }
}

extension StreamFormatDescription {
    /// The Video section's rows from AetherEngine's probe.
    static func codec(_ format: VideoStreamFormat, codecName: String?) -> String? {
        codec(name: codecName, profile: format.profile)
    }

    static func pixelFormat(_ format: VideoStreamFormat) -> String? {
        pixelFormat(name: format.pixelFormat, bitDepth: format.bitDepth)
    }

    static func color(_ format: VideoStreamFormat) -> String? {
        color(primaries: format.colorPrimaries, transfer: format.transfer, matrix: format.matrix, range: format.range)
    }

    /// "yuv420p10le → P010 (x420)": what the engine's software decoder
    /// produced and the CoreVideo buffer it was displayed from.
    static func decoded(_ format: DecodedVideoFormat) -> String {
        guard let frame = format.frame.pixelFormat else { return format.pixelBufferLabel }
        return "\(frame) → \(format.pixelBufferLabel)"
    }
}

extension StreamFormatDescription {
    /// The same rows from Jellyfin's probe, for a server transcode.
    static func codec(_ stream: MediaStream?) -> String? {
        codec(name: stream?.codec, profile: stream?.profile)
    }

    static func pixelFormat(_ stream: MediaStream?) -> String? {
        pixelFormat(name: stream?.pixelFormat, bitDepth: stream?.bitDepth)
    }

    /// Jellyfin reports no colour range, so this has one field fewer than the
    /// engine's.
    static func color(_ stream: MediaStream?) -> String? {
        color(primaries: stream?.colorPrimaries, transfer: stream?.colorTransfer, matrix: stream?.colorSpace, range: nil)
    }

    static func audioSampling(_ stream: MediaStream?) -> String? {
        audioSampling(sampleRate: stream?.sampleRate, bitsPerSample: stream?.bitDepth)
    }
}
