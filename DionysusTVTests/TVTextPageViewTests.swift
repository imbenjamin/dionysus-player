import SwiftUI
import XCTest
@testable import Dionysus

/// The Apple TV's License page: the app's license, then each library's
/// notices after a paragraph naming it in a bold heading.
final class TVTextPageViewTests: XCTestCase {
    func test_eachLibrary_followsItsName() {
        let paragraphs = TVTextPageView.licenseParagraphs(
            license: "App license.",
            components: [.init(name: "One", text: "First.\n\nStill first."), .init(name: "Two", text: "Second.")]
        )
        XCTAssertEqual(paragraphs.map { String($0.characters) },
                       ["App license.", "One", "First.", "Still first.", "Two", "Second."])
    }

    func test_aLibrarysName_isSetAsAHeading() throws {
        let paragraphs = TVTextPageView.licenseParagraphs(license: "App license.", components: [.init(name: "One", text: "Text.")])
        XCTAssertEqual(paragraphs[1].font, .title3.bold())
        XCTAssertNil(paragraphs[2].font, "The library's text is the page's body")
    }

    func test_aMissingLicense_saysSo_andTheLibrariesStillShow() {
        let paragraphs = TVTextPageView.licenseParagraphs(license: nil, components: [.init(name: "One", text: "Text.")])
        XCTAssertEqual(paragraphs.count, 3)
        XCTAssertEqual(String(paragraphs[1].characters), "One")
    }
}
