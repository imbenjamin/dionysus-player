import XCTest
@testable import Dionysus

/// Whose imagery a show's page draws, and that an item with none of its own
/// falls back to the ancestor the server names.
@MainActor
final class TVShowArtTests: XCTestCase {
    private let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)

    private func item(_ id: String, _ type: BaseItemKind, backdrops: [String] = [], parent: String? = nil, logo: String? = nil, parentLogo: String? = nil) -> MediaItem {
        var dto = BaseItemDto(id: id, name: id, type: type)
        dto.backdropImageTags = backdrops
        if let logo { dto.imageTags = ["Logo": logo] }
        if let parent {
            dto.parentBackdropItemId = parent
            dto.parentBackdropImageTags = ["pb"]
        }
        if let parentLogo {
            dto.parentLogoItemId = parentLogo
            dto.parentLogoImageTag = "pl"
        }
        return MediaItem(dto: dto, images: images)
    }

    func test_theEpisodeWins_thenTheChosenSeason_thenWhatThePageOpenedOn() {
        let show = item("show", .series), season = item("season", .season), episode = item("ep", .episode)
        XCTAssertEqual(TVShowDetailView.artItem(episode: episode, chosenSeason: season, loaded: show).id, "ep")
        XCTAssertEqual(TVShowDetailView.artItem(episode: nil, chosenSeason: season, loaded: show).id, "season")
        XCTAssertEqual(TVShowDetailView.artItem(episode: nil, chosenSeason: nil, loaded: show).id, "show")
    }

    func test_anEpisodesOwnBackdropAndLogo_areUsed() {
        let episode = item("ep", .episode, backdrops: ["b"], parent: "season", logo: "l", parentLogo: "show")
        XCTAssertTrue(episode.backdropImageURL?.path.contains("/Items/ep/") ?? false)
        XCTAssertTrue(episode.logoImageURL?.path.contains("/Items/ep/") ?? false)
    }

    func test_withoutItsOwn_anEpisodeUsesTheAncestorTheServerNames() {
        let episode = item("ep", .episode, parent: "season", parentLogo: "show")
        XCTAssertTrue(episode.backdropImageURL?.path.contains("/Items/season/") ?? false)
        XCTAssertTrue(episode.logoImageURL?.path.contains("/Items/show/") ?? false)
    }
}
