import XCTest
@testable import Dionysus

/// The License page shows the app's license, then each bundled library's
/// notices under its name, from the app's own bundle.
final class LicenseDocumentTests: XCTestCase {
    func test_theAppsLicense_isBundled() throws {
        let license = try XCTUnwrap(LicenseDocument.appLicense())
        XCTAssertTrue(license.contains("GNU GENERAL PUBLIC LICENSE"))
    }

    func test_libTrueHDsNotices_areBundledUnderItsName() throws {
        let libTrueHD = try XCTUnwrap(LicenseDocument.components().first { $0.name == "LibTrueHD" })
        XCTAssertTrue(libTrueHD.text.contains("MIT License"), "LibTrueHD's own license")
        XCTAssertTrue(libTrueHD.text.contains("Apache License"), "The truehd and oamd crates' license")
        XCTAssertFalse(libTrueHD.text.hasPrefix("#"), "The header line is the name, not text")
    }

    /// Every library that ships in the app, in the file's order. SMBClient
    /// isn't one: only AetherEngine's `AetherEngineSMB` product uses it.
    func test_everyShippedLibrary_hasItsNotices() {
        XCTAssertEqual(LicenseDocument.components().map(\.name), [
            "AetherEngine", "FFmpeg", "dav1d", "zimg", "libzvbi", "libdovi", "LibTrueHD", "LibDTSX",
            "libass", "fontconfig", "FreeType", "HarfBuzz", "FriBidi", "libpng",
            "swift-ass-renderer", "swift-libass", "SwiftUI-Shimmer",
            "swift-issue-reporting", "combine-schedulers", "swift-concurrency-extras"
        ])
        XCTAssertTrue(LicenseDocument.components().allSatisfy { !$0.text.isEmpty })
    }

    func test_theLGPLs_areBundled() throws {
        let libraries = LicenseDocument.components()
        let engine = try XCTUnwrap(libraries.first { $0.name == "AetherEngine" })
        XCTAssertTrue(engine.text.contains("GNU LESSER GENERAL PUBLIC LICENSE\n                       Version 3"))
        let ffmpeg = try XCTUnwrap(libraries.first { $0.name == "FFmpeg" })
        XCTAssertTrue(ffmpeg.text.contains("Version 2.1, February 1999"), "Also covers libzvbi and FriBidi")
    }

    func test_eachHeaderLine_startsALibrary() {
        let notices = "# One\n\nFirst text.\n\n# Two\nSecond\ntext.\n"
        XCTAssertEqual(LicenseDocument.components(in: notices), [
            .init(name: "One", text: "First text."),
            .init(name: "Two", text: "Second\ntext.")
        ])
    }

    func test_textBeforeTheFirstHeader_belongsToNoLibrary() {
        XCTAssertEqual(LicenseDocument.components(in: "Preamble\n# One\nText"), [.init(name: "One", text: "Text")])
        XCTAssertEqual(LicenseDocument.components(in: "No headers at all"), [])
    }

    func test_nothingBundled_meansNoLicenseAndNoLibraries() {
        let bundle = Bundle(for: Self.self)
        XCTAssertNil(LicenseDocument.appLicense(bundle: bundle))
        XCTAssertEqual(LicenseDocument.components(bundle: bundle), [])
    }
}
