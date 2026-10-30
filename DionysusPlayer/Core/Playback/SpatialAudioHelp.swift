import Foundation

/// The About Spatial Audio page: iOS's Learn More sheet and the Apple TV's
/// About Spatial Audio row show the same text, so the section's footer can
/// stay one sentence (Benjamin, 2026-10-23).
///
/// Never "beta": App Review rejects a store build with a feature labelled
/// beta (guideline 2.2). A fourth paragraph warned that a 4K title could
/// pause to buffer (AetherEngine #850) until 7.48.0 fixed it, checked on the
/// Living Room box (2026-10-25).
///
/// The receiver paragraph names every indicator a receiver may light
/// (Benjamin, 2026-10-30): tvOS wraps the bed in Dolby MAT, which some sinks
/// show as Atmos by themselves; AetherEngine's silent Atmos stream lights the
/// rest for TrueHD Atmos, and it never runs for DTS:X, so a DTS:X film can
/// show as multichannel PCM. Nothing reaches a receiver as DTS.
enum SpatialAudioHelp {
    static var paragraphs: [String] {
        [
            String(localized: "Dolby TrueHD and DTS-HD Master Audio can't be sent to a receiver or AirPods as they are, so Dolby Atmos and DTS:X tracks usually play as 5.1 and lose their height channels. With Spatial Audio on, Dionysus decodes them, height channels included, and plays them in your speaker layout as lossless multichannel audio."),
            String(localized: "A receiver or soundbar may show it as Dolby Atmos, Multichannel PCM or LPCM, depending on the model and on the track. Each means the height channels are there. It never shows as DTS:X, since a DTS:X track is decoded before it leaves the device. AirPods play it as Spatial Audio. Over AirPlay it's compressed instead, since AirPlay doesn't carry the uncompressed audio with its height channels."),
            String(localized: "Choose the speaker layout that matches your setup. 7.1.4 is the default and is recommended for AirPods. DTS:X offers 7.1.4 and 9.1.6."),
        ]
    }
}
