import XCTest
@testable import Dionysus

/// `BackdropLogoOverlay` is a rendering-only `View` — nothing to unit test
/// beyond `rotation(tiltX:tiltY:maxDegrees:)`, the one piece of actual
/// computation behind its device-tilt depth effect (see
/// `DeviceTiltObserverTests`' doc comment for the same reasoning).
final class BackdropLogoOverlayTests: XCTestCase {
    func test_rotation_zeroTilt_isZeroAngle() {
        let result = BackdropLogoOverlay.rotation(tiltX: 0, tiltY: 0, maxDegrees: 10)
        XCTAssertEqual(result.angle.degrees, 0)
    }

    func test_rotation_fullTiltOnOneAxis_reachesMaxDegrees() {
        let result = BackdropLogoOverlay.rotation(tiltX: 1, tiltY: 0, maxDegrees: 10)
        XCTAssertEqual(result.angle.degrees, 10, accuracy: 0.0001)
    }

    func test_rotation_partialTilt_scalesLinearlyWithMagnitude() {
        let result = BackdropLogoOverlay.rotation(tiltX: 0.5, tiltY: 0, maxDegrees: 10)
        XCTAssertEqual(result.angle.degrees, 5, accuracy: 0.0001)
    }

    /// Tilting right (`tiltX`) should rotate around a roughly-vertical
    /// axis, and tilting forward (`tiltY`) around a roughly-horizontal one
    /// — this is what actually separates "tip left/right" from "tip
    /// forward/back" into two visually distinct rotations rather than both
    /// looking the same. See the type's doc comment for the full reasoning.
    func test_rotation_xTiltOnly_rotatesAroundTheYAxis() {
        let result = BackdropLogoOverlay.rotation(tiltX: 1, tiltY: 0, maxDegrees: 10)
        XCTAssertEqual(result.axis.x, 0)
        XCTAssertNotEqual(result.axis.y, 0)
        XCTAssertEqual(result.axis.z, 0)
    }

    func test_rotation_yTiltOnly_rotatesAroundTheXAxis() {
        let result = BackdropLogoOverlay.rotation(tiltX: 0, tiltY: 1, maxDegrees: 10)
        XCTAssertNotEqual(result.axis.x, 0)
        XCTAssertEqual(result.axis.y, 0)
        XCTAssertEqual(result.axis.z, 0)
    }

    /// A combined diagonal tilt shouldn't exceed `maxDegrees` just because
    /// two components add up — the magnitude is the vector length of both
    /// components together, clamped, not their sum.
    func test_rotation_combinedTilt_clampsToMaxDegreesRatherThanExceedingIt() {
        let result = BackdropLogoOverlay.rotation(tiltX: 1, tiltY: 1, maxDegrees: 10)
        XCTAssertEqual(result.angle.degrees, 10, accuracy: 0.0001)
    }

    func test_rotation_diagonalTilt_producesBothAxisComponents() {
        let result = BackdropLogoOverlay.rotation(tiltX: 0.6, tiltY: 0.6, maxDegrees: 10)
        XCTAssertNotEqual(result.axis.x, 0)
        XCTAssertNotEqual(result.axis.y, 0)
    }
}
