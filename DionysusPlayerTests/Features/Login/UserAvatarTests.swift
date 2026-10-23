import SwiftUI
import XCTest
@testable import Dionysus

/// `UserAvatar` is the sign-in avatar on both iOS and Apple TV: the user's
/// Jellyfin profile picture over a monogram. The picture is fetched only when
/// the server says one exists, from the public user-image route.
@MainActor
final class UserAvatarTests: XCTestCase {
    private let server = URL(string: "https://jellyfin.example.com")!

    func test_imageURL_usesTheUserImageRouteWithTagAndWidth() throws {
        let user = UserDto(id: "user-1", name: "Ada", primaryImageTag: "tag-1")
        let url = try XCTUnwrap(UserAvatar.imageURL(for: user, serverURL: server, size: 200))
        XCTAssertEqual(url.path, "/Users/user-1/Images/Primary")
        let query = URLRequest(url: url).queryDictionary
        XCTAssertEqual(query["tag"], "tag-1")
        XCTAssertEqual(query["maxWidth"], "600")
    }

    /// No tag means the user never set a picture: the monogram stays, and
    /// nothing is requested.
    func test_imageURL_isNilWithoutATag() {
        let user = UserDto(id: "user-1", name: "Ada", primaryImageTag: nil)
        XCTAssertNil(UserAvatar.imageURL(for: user, serverURL: server, size: 200))
    }

    func test_imageURL_isNilWithoutAServer() {
        let user = UserDto(id: "user-1", name: "Ada", primaryImageTag: "tag-1")
        XCTAssertNil(UserAvatar.imageURL(for: user, serverURL: nil, size: 200))
    }

    /// A transparent picture (the demo server's is) sits on a plain dark
    /// ground: neither the monogram nor its bright colour shows through.
    func test_transparentPicture_hidesTheMonogramBehindIt() throws {
        let brightness = try centreBrightness(of: UserAvatar(
            user: UserDto(id: "user-1", name: "Ada", primaryImageTag: "tag-1"),
            serverURL: server, size: 200, image: Self.transparentImage
        ))
        XCTAssertLessThan(brightness, 0.25)
    }

    /// Without a picture the monogram's colour shows, so the check above can
    /// tell the two apart.
    func test_noPicture_showsTheMonogram() throws {
        let brightness = try centreBrightness(of: UserAvatar(
            user: UserDto(id: "user-1", name: "Ada", primaryImageTag: nil),
            serverURL: server, size: 200
        ))
        XCTAssertGreaterThan(brightness, 0.45)
    }

    private static let transparentImage: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { _ in }
    }()

    /// The mean of each pixel's brightest channel over the middle half of the
    /// avatar, where the monogram is drawn.
    private func centreBrightness(of avatar: UserAvatar) throws -> Double {
        let renderer = ImageRenderer(content: avatar)
        renderer.scale = 1
        let cgImage = try XCTUnwrap(renderer.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0, count = 0.0
        for y in height / 4 ..< height * 3 / 4 {
            for x in width / 4 ..< width * 3 / 4 {
                let i = (y * width + x) * 4
                total += Double(max(pixels[i], pixels[i + 1], pixels[i + 2])) / 255
                count += 1
            }
        }
        return total / count
    }
}
