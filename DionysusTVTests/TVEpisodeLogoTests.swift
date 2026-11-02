import XCTest
@testable import Dionysus

/// As on iOS (`episodeLogoOverlay`), an episode tile carries its show's logo
/// bottom-left, since an episode's still says nothing of which show it is.
/// Only episodes, and only when a logo exists up the chain.
@MainActor
final class TVEpisodeLogoTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)

    private func item(_ type: BaseItemKind, logo: Bool) -> MediaItem {
        var dto = BaseItemDto(id: "x", name: "x", type: type)
        if logo {
            dto.parentLogoItemId = "series-1"
            dto.parentLogoImageTag = "logo-tag"
        }
        return MediaItem(dto: dto, images: images)
    }

    func test_anEpisode_carriesItsShowsLogo() {
        XCTAssertEqual(TVEpisodeLogo.url(for: item(.episode, logo: true))?.path, "/Items/series-1/Images/Logo")
    }

    func test_anEpisodeWithNoLogoUpTheChain_carriesNone() {
        XCTAssertNil(TVEpisodeLogo.url(for: item(.episode, logo: false)))
    }

    func test_otherKinds_carryNone_evenWithALogo() {
        XCTAssertNil(TVEpisodeLogo.url(for: item(.movie, logo: true)))
        XCTAssertNil(TVEpisodeLogo.url(for: item(.series, logo: true)))
    }
}
