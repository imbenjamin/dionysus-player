import SwiftUI
import XCTest
@testable import Dionysus

/// Under Reduce Motion nothing slides or grows: the change lands at once.
final class TVMotionTests: XCTestCase {
    func test_moving_withoutReduceMotion_keepsTheAnimation() {
        XCTAssertEqual(TVMotion.moving(.easeOut(duration: 0.2), reduceMotion: false), .easeOut(duration: 0.2))
    }

    func test_moving_underReduceMotion_hasNoAnimation() {
        XCTAssertNil(TVMotion.moving(.easeOut(duration: 0.2), reduceMotion: true))
    }
}

/// Under Increase Contrast, text and marks drawn translucent over artwork
/// are drawn solid.
final class TVContrastTests: XCTestCase {
    func test_opacity_atStandardContrast_isAsDesigned() {
        XCTAssertEqual(TVContrast.opacity(0.82, increased: false), 0.82)
    }

    func test_opacity_underIncreaseContrast_isSolid() {
        XCTAssertEqual(TVContrast.opacity(0.82, increased: true), 1)
    }
}
