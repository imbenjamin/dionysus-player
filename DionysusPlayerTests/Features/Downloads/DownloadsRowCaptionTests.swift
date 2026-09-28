import XCTest
@testable import Dionysus

final class DownloadsRowCaptionTests: XCTestCase {
    private let megabyte: Int64 = 54_200_000

    func test_appendsSizeAfterTheParts() throws {
        let caption = try XCTUnwrap(DownloadsRowCaption(
            parts: [.init(text: "2 Episodes")],
            sizeBytes: megabyte
        ))
        XCTAssertEqual(caption.text, "2 Episodes \u{00B7} \(FileSizeText.text(bytes: megabyte))")
    }

    /// VoiceOver gets each part's spoken form, comma-joined, rather than the
    /// visible "1h 32m · 54.2 MB" it would read letter by letter.
    func test_accessibilityTextUsesSpokenForms() throws {
        let caption = try XCTUnwrap(DownloadsRowCaption(
            parts: [.init(text: "2019 \u{00B7} 1h 32m", spoken: "2019, 1 hour, 32 minutes")],
            sizeBytes: megabyte
        ))
        XCTAssertEqual(
            caption.accessibilityText,
            "2019, 1 hour, 32 minutes, \(FileSizeText.accessibilityText(bytes: megabyte))"
        )
    }

    func test_partWithoutSpokenFormIsReadAsShown() throws {
        let caption = try XCTUnwrap(DownloadsRowCaption(parts: [.init(text: "S1:E4 \u{00B7} Pilot")], sizeBytes: nil))
        XCTAssertEqual(caption.text, "S1:E4 \u{00B7} Pilot")
        XCTAssertEqual(caption.accessibilityText, "S1:E4 \u{00B7} Pilot")
    }

    /// Nothing completed yet: no "0 B".
    func test_zeroOrMissingSizeIsLeftOut() throws {
        XCTAssertEqual(DownloadsRowCaption(parts: [.init(text: "2019")], sizeBytes: 0)?.text, "2019")
        XCTAssertEqual(DownloadsRowCaption(parts: [.init(text: "2019")], sizeBytes: nil)?.text, "2019")
    }

    func test_sizeAloneStillShows() throws {
        XCTAssertEqual(DownloadsRowCaption(parts: [], sizeBytes: megabyte)?.text, FileSizeText.text(bytes: megabyte))
    }

    func test_nothingToShowIsNil() {
        XCTAssertNil(DownloadsRowCaption(parts: [], sizeBytes: nil))
        XCTAssertNil(DownloadsRowCaption(parts: [], sizeBytes: 0))
    }
}
