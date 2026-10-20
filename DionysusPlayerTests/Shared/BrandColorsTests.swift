import SwiftUI
import UIKit
import XCTest
@testable import Dionysus

/// Pins the rose gold accent (Benjamin, 2026-10-20) to the contrast its doc
/// comments claim, and the adaptive colours to the branch each appearance
/// takes, so a palette change that breaks either fails here rather than on
/// screen.
final class BrandColorsTests: XCTestCase {
    func test_roseGold_isTheMeasuredHex() {
        XCTAssertEqual(hex(.dionysusRoseGold), "F2A38C")
        XCTAssertEqual(hex(.dionysusRoseGoldHighContrast), "A8513C")
        XCTAssertEqual(hex(.dionysusRoseGoldLight), "F7C2A8")
    }

    /// The light-mode progress bar sits on the burgundy Play button.
    func test_roseGold_clearsBurgundy() {
        XCTAssertGreaterThanOrEqual(contrast(.dionysusRoseGold, .dionysusBurgundy), 4.5)
    }

    /// Increase Contrast's swap exists for a white background.
    func test_roseGoldHighContrast_clearsWhite() {
        XCTAssertGreaterThanOrEqual(contrast(.dionysusRoseGoldHighContrast, .white), 4.5)
    }

    /// The Apple TV's rating star is text on its near-black pages.
    func test_roseGoldLight_clearsDarkBackground() {
        let dark = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
        XCTAssertGreaterThanOrEqual(contrast(.dionysusRoseGoldLight, dark), 4.5)
    }

    func test_progress_isRoseGoldInLight_burgundyInDark() {
        XCTAssertEqual(hex(.dionysusProgress, .light), hex(.dionysusRoseGold))
        XCTAssertEqual(hex(.dionysusProgress, .light, highContrast: true), hex(.dionysusRoseGoldHighContrast))
        XCTAssertEqual(hex(.dionysusProgress, .dark), hex(.dionysusBurgundy))
    }

    /// Item progress bars, placeholders and page dots read the same in both
    /// appearances and on the Apple TV, which is always dark.
    func test_highlight_isRoseGoldInBothAppearances() {
        XCTAssertEqual(hex(.dionysusHighlight, .light), hex(.dionysusRoseGold))
        XCTAssertEqual(hex(.dionysusHighlight, .light, highContrast: true), hex(.dionysusRoseGoldHighContrast))
        XCTAssertEqual(hex(.dionysusHighlight, .dark), hex(.dionysusRoseGold))
        XCTAssertEqual(hex(.dionysusHighlight, .dark, highContrast: true), hex(.dionysusRoseGoldLight))
    }

    /// The Apple TV's signed-in badge draws burgundy on the highlight.
    func test_burgundy_clearsRoseGold() {
        XCTAssertGreaterThanOrEqual(contrast(.dionysusBurgundy, .dionysusRoseGold), 4.5)
    }

    // MARK: - Helpers

    private func components(
        _ color: Color, _ style: UIUserInterfaceStyle = .light, highContrast: Bool = false
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = highContrast ? .high : .normal
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    private func hex(_ color: Color, _ style: UIUserInterfaceStyle = .light, highContrast: Bool = false) -> String {
        let c = components(color, style, highContrast: highContrast)
        return String(format: "%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    /// WCAG 2 contrast ratio from relative luminance.
    private func contrast(_ a: Color, _ b: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            let c = components(color)
            func linear(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
        }
        let l = [luminance(a), luminance(b)].sorted(by: >)
        return (l[0] + 0.05) / (l[1] + 0.05)
    }
}
