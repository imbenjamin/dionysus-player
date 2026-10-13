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
