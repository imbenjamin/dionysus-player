import XCTest
@testable import Dionysus

final class FileSizeTextTests: XCTestCase {
    func test_text_formatsAsFileByteCount() {
        // 1.5 GB in `.file` count style (decimal, 1000-based) — matches
        // `ByteCountFormatter`'s own established behavior elsewhere in this
        // app (e.g. `DownloadsSettingsView`'s storage bar), not verifying
        // `ByteCountFormatter` itself so much as confirming this type is a
        // thin, unmodified pass-through to it.
        XCTAssertEqual(FileSizeText.text(bytes: 1_500_000_000), "1.5 GB")
    }

    // MARK: accessibilityText — spells out the unit, matching the two
    // pre-existing per-view copies this consolidates for new call sites
    // (`DownloadedDetailTabsView.fileSizeAccessibilityText`,
    // `DownloadedInfoMetadataRow.spokenFileSize(_:)`)

    func test_accessibilityText_spellsOutGigabytes() {
        XCTAssertEqual(FileSizeText.accessibilityText(bytes: 1_500_000_000), "1.5 gigabytes")
    }

    func test_accessibilityText_spellsOutMegabytes() {
        XCTAssertEqual(FileSizeText.accessibilityText(bytes: 25_000_000), "25 megabytes")
    }

    /// `ByteCountFormatter` special-cases zero as "Zero KB", not "0 bytes"
    /// — asserting against its own `text(bytes:)` output rather than a
    /// hand-guessed string, so this can't drift from whatever
    /// `ByteCountFormatter` actually does.
    func test_accessibilityText_zeroBytes_matchesFormattersOwnZeroCase() {
        XCTAssertEqual(FileSizeText.text(bytes: 0), "Zero KB")
        XCTAssertEqual(FileSizeText.accessibilityText(bytes: 0), "Zero kilobytes")
    }
}
