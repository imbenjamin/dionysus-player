import XCTest
@testable import Dionysus

/// Review Focus 3: every title lands under a letter the bar shows.
final class TVAlphabetIndexTests: XCTestCase {
    func test_theBarIsHashThenAToZ() {
        XCTAssertEqual(TVAlphabetIndex.letters.count, 27)
        XCTAssertEqual(TVAlphabetIndex.letters.first, "#")
        XCTAssertEqual(TVAlphabetIndex.letters.last, "Z")
    }

    func test_plainTitles() {
        XCTAssertEqual(TVAlphabetIndex.letter(for: "Dracula"), "D")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "sahara"), "S")
    }

    /// Jellyfin's sort name drops a leading article, so the grid's order does
    /// too: "The Boy in the Plastic Bubble" sits among the Bs.
    func test_leadingArticles_areSkipped() {
        XCTAssertEqual(TVAlphabetIndex.letter(for: "The Boy in the Plastic Bubble"), "B")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "A Quiet Place"), "Q")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "An Education"), "E")
        // Not an article: the word only starts with one.
        XCTAssertEqual(TVAlphabetIndex.letter(for: "Theory of Everything"), "T")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "Andor"), "A")
        // A title that is only the article keeps its own letter.
        XCTAssertEqual(TVAlphabetIndex.letter(for: "The"), "T")
    }

    func test_accents_foldToTheirLetter() {
        XCTAssertEqual(TVAlphabetIndex.letter(for: "Élite"), "E")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "Ødegaard"), "O")
    }

    func test_digits_punctuation_nonLatin_andEmpty_goUnderHash() {
        XCTAssertEqual(TVAlphabetIndex.letter(for: "12 Angry Men"), "#")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "(500) Days of Summer"), "#")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "千と千尋の神隠し"), "#")
        XCTAssertEqual(TVAlphabetIndex.letter(for: ""), "#")
        XCTAssertEqual(TVAlphabetIndex.letter(for: "   "), "#")
    }

    func test_firstItemIDs_takesTheFirstInListOrder_perLetter() {
        let items = [(id: "1", name: "12 Angry Men"), (id: "2", name: "Andor"), (id: "3", name: "Arrival"), (id: "4", name: "The Boy")]
        let index = TVAlphabetIndex.firstItemIDs(items)
        XCTAssertEqual(index["#"], "1")
        XCTAssertEqual(index["A"], "2")
        XCTAssertEqual(index["B"], "4")
        XCTAssertNil(index["C"])
    }

    /// Descending order: the first in list order is still the jump target.
    func test_firstItemIDs_inDescendingOrder() {
        let items = [(id: "3", name: "Arrival"), (id: "2", name: "Andor")]
        XCTAssertEqual(TVAlphabetIndex.firstItemIDs(items)["A"], "3")
    }

    func test_everyTitleIsReachable() {
        let names = ["", "7", "Élite", "The", "the matrix", "zebra", "千"]
        for name in names {
            XCTAssertTrue(TVAlphabetIndex.letters.contains(TVAlphabetIndex.letter(for: name)), "\"\(name)\" has no letter on the bar")
        }
    }

    func test_indexTitles_areOnlyTheLettersWithTitles_inBarOrder() {
        XCTAssertEqual(TVAlphabetIndex.indexTitles(["Zodiac", "12 Angry Men", "The Abyss", "Arrival"]), ["#", "A", "Z"])
    }

    func test_indexTitles_areNil_withNothingToJumpBetween() {
        XCTAssertNil(TVAlphabetIndex.indexTitles(["Alien", "Arrival"]))
        XCTAssertNil(TVAlphabetIndex.indexTitles([]))
    }

    func test_firstIndexUnderATitle_isTheFirstInListOrder() {
        let names = ["12 Angry Men", "The Abyss", "Arrival", "Zodiac"]
        XCTAssertEqual(TVAlphabetIndex.firstIndex(under: "A", in: names), 1)
        XCTAssertEqual(TVAlphabetIndex.firstIndex(under: "#", in: names), 0)
        XCTAssertNil(TVAlphabetIndex.firstIndex(under: "Q", in: names))
    }
}
