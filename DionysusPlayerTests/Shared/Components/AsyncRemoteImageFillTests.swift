import XCTest
@testable import Dionysus

/// What `AsyncRemoteImage` draws for each load state. The shimmering glyph
/// while loading and the settled glyph after a failure are the app-wide
/// placeholder; `showsPlaceholder: false` (the Apple TV detail backdrop)
/// draws nothing in either.
@MainActor
final class AsyncRemoteImageFillTests: XCTestCase {
    func test_loading_showsTheShimmeringGlyph() {
        XCTAssertEqual(AsyncRemoteImage.fill(.loading, showsPlaceholder: true), .loadingGlyph)
    }

    func test_failed_showsTheSettledGlyph() {
        XCTAssertEqual(AsyncRemoteImage.fill(.failed, showsPlaceholder: true), .settledGlyph)
    }

    func test_loaded_showsTheImage_whateverThePlaceholderSetting() {
        XCTAssertEqual(AsyncRemoteImage.fill(.loaded, showsPlaceholder: true), .image)
        XCTAssertEqual(AsyncRemoteImage.fill(.loaded, showsPlaceholder: false), .image)
    }

    func test_withoutAPlaceholder_loadingAndFailureDrawNothing() {
        XCTAssertEqual(AsyncRemoteImage.fill(.loading, showsPlaceholder: false), .nothing)
        XCTAssertEqual(AsyncRemoteImage.fill(.failed, showsPlaceholder: false), .nothing)
    }
}
