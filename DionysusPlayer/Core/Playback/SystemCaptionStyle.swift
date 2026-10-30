import AetherEngine
import Foundation
import Observation

/// The system caption style (Settings › Accessibility › Subtitles &
/// Captioning) as a `SubtitleTextStyle`, kept current while the app runs.
/// AetherEngine reads it (`SubtitleCaptionStyle`, 7.48.0) for its own software
/// renderer; the app draws its own overlay, so it reads the same thing here.
@Observable
@MainActor
final class SystemCaptionStyle {
    static let shared = SystemCaptionStyle()

    /// The Dionysus look with whatever the user changed in Settings laid over
    /// it; exactly `.dionysus` when nothing was.
    private(set) var style: SubtitleTextStyle

    @ObservationIgnored private var observation: SubtitleCaptionStyle.Observation?

    private init() {
        #if DEBUG
        if UITestConfiguration.isActive, UITestConfiguration.usesCustomCaptionStyle {
            style = SubtitleTextStyle(system: Self.uiTestStyle)
            return
        }
        #endif
        style = SubtitleTextStyle(system: .current())
        // Called on an arbitrary thread, and not again once released.
        observation = SubtitleCaptionStyle.observeChanges { [weak self] newStyle in
            Task { @MainActor in self?.style = SubtitleTextStyle(system: newStyle) }
        }
    }

    #if DEBUG
    /// A style no default could be mistaken for, for the journeys: twice the
    /// size, yellow over the cue's own colours, a window.
    static let uiTestStyle = SubtitleCaptionStyle(
        sizeScale: 2,
        textColor: .init(SubtitleColor(r: 255, g: 255, b: 0), precedence: .overridesCue),
        windowOpacity: .init(0.4)
    )
    #endif
}

extension SubtitleTextStyle {
    /// Each field the user left alone keeps the Dionysus look, as AetherEngine
    /// documents for a host drawing its own overlay. The background is the
    /// Dionysus panel, so a chosen background restyles that panel; the window
    /// is a second panel behind it.
    init(system: SubtitleCaptionStyle) {
        self = .dionysus
        fontName = system.fontName?.value
        if system.sizeScale.isFinite, system.sizeScale > 0 {
            sizeScale = system.sizeScale
        }

        textOpacity = system.textOpacity?.value ?? 1
        let text = system.textColor.map { Self.rgba($0.value, opacity: textOpacity) }
        textColor = text ?? RGBA(red: 1, green: 1, blue: 1, opacity: textOpacity)
        textColorOverridesCue = system.textColor?.precedence == .overridesCue

        if system.backgroundColor != nil || system.backgroundOpacity != nil {
            let opacity = system.backgroundOpacity?.value ?? background?.opacity ?? 0
            background = opacity > 0
                ? Self.rgba(system.backgroundColor?.value ?? SubtitleColor(r: 0, g: 0, b: 0), opacity: opacity)
                : nil
        }

        if let opacity = system.windowOpacity?.value, opacity > 0 {
            window = Self.rgba(system.windowColor?.value ?? SubtitleColor(r: 0, g: 0, b: 0), opacity: opacity)
        }

        switch system.edgeStyle?.value {
        case nil: break
        case .none?: edge = .none
        case .dropShadow?: edge = .dropShadow
        case .raised?: edge = .raised
        case .depressed?: edge = .depressed
        case .uniform?: edge = .outline
        }
    }

    private static func rgba(_ color: SubtitleColor, opacity: Double) -> RGBA {
        RGBA(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255,
             opacity: min(max(opacity, 0), 1))
    }
}
