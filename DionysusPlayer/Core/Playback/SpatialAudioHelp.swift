import Foundation

/// The About Spatial Audio page: iOS's Learn More sheet and the Apple TV's
/// About Spatial Audio row show the same text, so the section's footer can
/// stay one sentence (Benjamin, 2026-10-23).
///
/// Never "beta": App Review rejects a store build with a feature labelled
/// beta (guideline 2.2). A fourth paragraph warned that a 4K title could
/// pause to buffer (AetherEngine #850) until 7.48.0 fixed it, checked on the
/// Living Room box (2026-10-25).
enum SpatialAudioHelp {
    static var paragraphs: [String] {
        [
            String(localized: "Dolby TrueHD and DTS-HD Master Audio can't be sent to a receiver or AirPods as they are, so Dolby Atmos and DTS:X tracks usually play as 5.1 and lose their height channels. With Spatial Audio on, Dionysus decodes the height channels and re-encodes them as Spatial Audio."),
            String(localized: "A receiver or soundbar shows the result as Dolby Atmos, DTS:X tracks included, and AirPods play it as Spatial Audio. The audio is re-encoded, so it isn't lossless."),
            String(localized: "Choose the speaker layout that matches your setup. 7.1.4 is the default and is recommended for AirPods. DTS:X offers 7.1.4 and 9.1.6."),
        ]
    }
}
