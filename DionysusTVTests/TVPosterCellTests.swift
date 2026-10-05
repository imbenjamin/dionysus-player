import UIKit
import XCTest
@testable import Dionysus

/// A poster still loading, or with no artwork, is drawn the size loaded
/// artwork is (Benjamin, 2026-10-05). The system poster insets its artwork
/// for the focus lift, working the inset out from its image; with no image
/// the placeholder filled the whole frame and drew larger than the posters
/// around it.
@MainActor
final class TVPosterCellTests: XCTestCase {
    private var window: UIWindow?

    /// On screen, as the inset is worked out in a layout pass there.
    private func cell(showing item: MediaItem) -> TVPosterCell {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        let cell = TVPosterCell(frame: CGRect(origin: CGPoint(x: 100, y: 100), size: TVPosterCollection.cellSize(.poster)))
        host.view.addSubview(cell)
        cell.show(item, shape: .poster) {}
        for _ in 0..<3 {
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return cell
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private let images = ImageURLBuilder(baseURL: URL(string: "http://h")!, accessToken: nil)

    func test_aPosterWithoutArtwork_isInsetLikeArtwork() {
        let item = MediaItem(dto: BaseItemDto(id: "m", name: "M", type: .movie), images: images)
        let cell = cell(showing: item)
        XCTAssertNotNil(cell.poster.image, "A stand-in, so the system insets it")
        XCTAssertLessThan(cell.poster.imageView.overlayContentView.bounds.width, TVTileShape.poster.gridSize.width, "Inset for the lift, as loaded artwork is")
    }

    func test_aPosterStillLoading_isInsetLikeArtwork() {
        var dto = BaseItemDto(id: "m", name: "M", type: .movie)
        dto.imageTags = ["Primary": "t"]
        let cell = cell(showing: MediaItem(dto: dto, images: images))
        XCTAssertNotNil(cell.poster.image)
        XCTAssertLessThan(cell.poster.imageView.overlayContentView.bounds.width, TVTileShape.poster.gridSize.width)
    }
}
