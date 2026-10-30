import SwiftUI
import XCTest
import AetherEngine
@testable import Dionysus

/// System lays what the user changed in Settings over the Dionysus
/// look, field by field (`SubtitleTextStyle.init(system:)`).
final class SystemCaptionStyleTests: XCTestCase {
    private let yellow = SubtitleColor(r: 255, g: 255, b: 0)

    /// Someone who never opened the page sees no difference.
    func test_nothingChanged_isTheDionysusLook() {
        XCTAssertEqual(SubtitleTextStyle(system: .standard), .dionysus)
    }

    func test_sizeAndFont_comeFromTheSystem() {
        let style = SubtitleTextStyle(system: SubtitleCaptionStyle(fontName: .init("Menlo"), sizeScale: 1.5))
        XCTAssertEqual(style.sizeScale, 1.5)
        XCTAssertEqual(style.fontName, "Menlo")
        XCTAssertEqual(style.background, SubtitleTextStyle.dionysus.background, "Untouched fields keep the Dionysus look")
        XCTAssertEqual(style.edge, .softShadow)
    }

    /// The system's "override" precedence beats a cue's own colour; its
    /// default lets the cue keep it.
    func test_textColour_precedenceAgainstTheCue() {
        let overriding = SubtitleTextStyle(system: SubtitleCaptionStyle(textColor: .init(yellow, precedence: .overridesCue)))
        XCTAssertEqual(overriding.textColor, .init(red: 1, green: 1, blue: 0, opacity: 1))
        XCTAssertNil(overriding.runColor(.red), "The user's colour wins over the cue's")

        let yielding = SubtitleTextStyle(system: SubtitleCaptionStyle(textColor: .init(yellow, precedence: .yieldsToCue)))
        XCTAssertEqual(yielding.runColor(.red), .red, "The cue's colour wins")
        XCTAssertNil(yielding.runColor(nil), "A run without a colour takes the user's")
    }

    func test_textOpacity_appliesToTheCuesColourToo() {
        let style = SubtitleTextStyle(system: SubtitleCaptionStyle(textOpacity: .init(0.5)))
        XCTAssertEqual(style.textColor, .init(red: 1, green: 1, blue: 1, opacity: 0.5))
        XCTAssertEqual(style.runColor(.red), Color.red.opacity(0.5))
    }

    /// The background restyles the Dionysus panel; a colour alone keeps its
    /// opacity, and a transparent one draws no panel.
    func test_background_restylesThePanel() {
        let coloured = SubtitleTextStyle(system: SubtitleCaptionStyle(backgroundColor: .init(yellow)))
        XCTAssertEqual(coloured.background, .init(red: 1, green: 1, blue: 0, opacity: 0.55))

        let opaque = SubtitleTextStyle(system: SubtitleCaptionStyle(backgroundOpacity: .init(1)))
        XCTAssertEqual(opaque.background, .black(1))

        let clear = SubtitleTextStyle(system: SubtitleCaptionStyle(backgroundOpacity: .init(0)))
        XCTAssertNil(clear.background)
    }

    func test_window_drawsOnlyOnceTurnedOn() {
        XCTAssertNil(SubtitleTextStyle(system: SubtitleCaptionStyle(windowColor: .init(yellow))).window,
                     "The system's window is transparent until its opacity is raised")
        let style = SubtitleTextStyle(system: SubtitleCaptionStyle(windowColor: .init(yellow), windowOpacity: .init(0.4)))
        XCTAssertEqual(style.window, .init(red: 1, green: 1, blue: 0, opacity: 0.4))
    }

    func test_edgeStyles() {
        let cases: [(SubtitleCaptionStyle.EdgeStyle, SubtitleTextStyle.Edge)] = [
            (.none, .none), (.dropShadow, .dropShadow), (.raised, .raised), (.depressed, .depressed), (.uniform, .outline),
        ]
        for (system, edge) in cases {
            XCTAssertEqual(SubtitleTextStyle(system: SubtitleCaptionStyle(edgeStyle: .init(system))).edge, edge)
        }
    }

    func test_matchSystem_isTheDefault() {
        XCTAssertEqual(subtitleAppearanceDefault, .system)
    }
}
