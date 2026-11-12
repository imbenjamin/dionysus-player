import XCTest
@testable import Dionysus

/// A `dionysus://item` link's season and section (#406).
final class DeepLinkItemOptionsTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "https://jellyfin.example.com")!, accessToken: "tok")

    private var seasons: [MediaItem] {
        [(0, "s0"), (1, "s1"), (2, "s2")].map { number, id in
            MediaItem(dto: BaseItemDto(id: id, name: "Season \(number)", type: .season, indexNumber: number), images: images)
        }
    }

    func test_seasonID_byIdOrNumber() {
        XCTAssertEqual(DeepLink.ItemOptions.seasonID(for: "s2", in: seasons), "s2")
        XCTAssertEqual(DeepLink.ItemOptions.seasonID(for: "1", in: seasons), "s1")
        XCTAssertEqual(DeepLink.ItemOptions.seasonID(for: "0", in: seasons), "s0", "Specials")
    }

    func test_seasonID_aSeasonTheShowDoesntHave_isNil() {
        XCTAssertNil(DeepLink.ItemOptions.seasonID(for: "7", in: seasons))
        XCTAssertNil(DeepLink.ItemOptions.seasonID(for: "nope", in: seasons))
        XCTAssertNil(DeepLink.ItemOptions.seasonID(for: "1", in: []))
    }

    func test_missingSeasonNotice_saysWhich_orThatOnlyShowsHaveThem() {
        XCTAssertEqual(DeepLink.ItemOptions.missingSeasonNotice("7", isShow: true), "This show has no season 7.")
        XCTAssertEqual(DeepLink.ItemOptions.missingSeasonNotice("7", isShow: false), "Only a show has seasons.")
    }

    func test_isEmpty() {
        XCTAssertTrue(DeepLink.ItemOptions().isEmpty)
        XCTAssertFalse(DeepLink.ItemOptions(season: "1").isEmpty)
        XCTAssertFalse(DeepLink.ItemOptions(section: .cast).isEmpty)
    }

    func test_eachSection_saysWhenItsMissing() {
        XCTAssertEqual(DeepLink.ItemOptions.Section.cast.missingNotice, "This title has no cast listed.")
        XCTAssertEqual(DeepLink.ItemOptions.Section.chapters.missingNotice, "This title has no chapters to show.")
        XCTAssertEqual(DeepLink.ItemOptions.Section.details.missingNotice, "This title has no details to show.")
        XCTAssertEqual(DeepLink.ItemOptions.Section.similar.missingNotice, "There's nothing like this title yet.")
    }

    func test_itemNotice_onlyForTheSection() {
        XCTAssertEqual(DeepLink.Issue.unknownSection.itemNotice, "Couldn't read the section.")
        XCTAssertNil(DeepLink.Issue.unknownSort.itemNotice)
    }
}
