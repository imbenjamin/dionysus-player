#if DEBUG
import SwiftUI
import UIKit

/// The `scrubThumbnails` scenario's trickplay track: one 2×2 sheet of
/// 320×180 tiles, each a solid colour, so a journey can tell which tile the
/// scrub bubble shows from the still alone (`UITestScrubPreviewLog`).
///
/// A still every second: any scrub past 0:03 clamps to the last tile, so
/// dragging to either end of the scrubber names a tile whatever the
/// item's runtime.
enum UITestTrickplay {
    static let info = TrickplayInfo(
        width: 320, height: 180, tileWidth: 2, tileHeight: 2,
        thumbnailCount: 4, interval: 1000, bandwidth: 0
    )

    /// Row-major, as `TrickplayMath` reads the sheet.
    static let tileColours: [(name: String, colour: UIColor)] = [
        ("red", .red), ("green", .green), ("blue", .blue), ("yellow", .yellow)
    ]

    static let sheetJPEG: Data = {
        let size = CGSize(width: info.width * info.tileWidth, height: info.height * info.tileHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for (index, tile) in tileColours.enumerated() {
                tile.colour.setFill()
                context.fill(CGRect(
                    x: (index % info.tileWidth) * info.width, y: (index / info.tileWidth) * info.height,
                    width: info.width, height: info.height
                ))
            }
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }()

    /// "320×180 blue": the still's size and the tile colour nearest its
    /// centre pixel (JPEG shifts the exact values).
    static func describe(_ image: CGImage) -> String {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Draws the image so its centre pixel lands on the 1×1 context.
            context.draw(image, in: CGRect(
                x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2),
                width: CGFloat(image.width), height: CGFloat(image.height)
            ))
            return true
        }
        let size = "\(image.width)×\(image.height)"
        guard drawn else { return size }
        let nearest = tileColours.min { lhs, rhs in
            distance(pixel, lhs.colour) < distance(pixel, rhs.colour)
        }
        return "\(size) \(nearest?.name ?? "")"
    }

    private static func distance(_ pixel: [UInt8], _ colour: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let components = [red, green, blue].map { $0 * 255 }
        return zip(pixel.prefix(3), components).reduce(0) { sum, pair in
            sum + pow(CGFloat(pair.0) - pair.1, 2)
        }
    }
}

/// What the scrub bubble last showed, for a journey to read after the drag
/// that showed it has ended (XCUITest can't query mid-gesture).
@MainActor
@Observable
final class UITestScrubPreviewLog {
    static let shared = UITestScrubPreviewLog()
    var last: String?
}

/// A one-point text carrying `UITestScrubPreviewLog`'s last entry, mounted
/// under the `scrubThumbnails` scenario only.
struct UITestScrubPreviewProbe: View {
    var body: some View {
        if UITestConfiguration.isActive, UITestConfiguration.scenario == .scrubThumbnails {
            Text(verbatim: UITestScrubPreviewLog.shared.last ?? "")
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier(A11yID.UITest.lastScrubPreview)
        }
    }
}
#endif
