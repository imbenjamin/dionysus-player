import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Where the Top Shelf art's overlay goes (M6). tvOS 27 draws no text over a
/// third-party carousel, so the title's logo (or name), the context line and
/// the time remaining are drawn into the image (Benjamin, 2026-10-14). The block
/// sits left and ends above the bottom third: the compact shelf covers the
/// image's bottom with the app dock, and full screen puts Play and More Info
/// at its bottom centre. It starts clear of full screen's left arrow.
enum TopShelfArtworkLayout {
    static let canvas = CGSize(width: 1920, height: 1080)
    /// The block's bottom, as a fraction of the height.
    static let blockBottom: CGFloat = 0.68
    private static let leading: CGFloat = 200
    private static let logoBox = CGSize(width: 520, height: 200)

    /// "1h 45m remaining", under the context line.
    static var remainingRect: CGRect {
        CGRect(x: leading, y: canvas.height * blockBottom - 44, width: 720, height: 44)
    }

    static var contextRect: CGRect {
        CGRect(x: leading, y: remainingRect.minY - 4 - 44, width: 720, height: 44)
    }

    /// The logo box's bottom line, shared by the name drawn in its place.
    static var logoBaseline: CGFloat { contextRect.minY - 18 }

    /// Fits the logo in its box, keeping its aspect, on the baseline.
    static func logoRect(logoSize: CGSize) -> CGRect {
        guard logoSize.width > 0, logoSize.height > 0 else {
            return CGRect(x: leading, y: logoBaseline - logoBox.height, width: logoBox.width, height: logoBox.height)
        }
        let scale = min(logoBox.width / logoSize.width, logoBox.height / logoSize.height)
        let size = CGSize(width: logoSize.width * scale, height: logoSize.height * scale)
        return CGRect(x: leading, y: logoBaseline - size.height, width: size.width, height: size.height)
    }
}

/// Draws the art (M6) with Core Graphics and Core Text only. A UIKit render
/// (`UIGraphicsPushContext`, `UIImage.draw`, `NSString.draw`) worked on the
/// Simulator but the extension died at its first draw on Bedroom every time
/// (2026-10-14), and Sodalite's renderer keeps out of UIKit because the
/// extension has no window scene. Memory is tight too, 17MB left at render:
/// the canvas is 1280 wide (`pixelWidth`; 1920 died every time on Bedroom,
/// and Benjamin judged 1280 sharp enough), the backdrop is decoded straight
/// to that size and the logo at the size it's drawn, and the result goes
/// straight back to JPEG. The layout stays in UIKit's
/// top-left 1920-point space; `Flip` converts.
enum TopShelfArtworkRenderer {
    private static let width: CGFloat = 1280
    /// Measured before the backdrop downloads, which took about 4MB more on
    /// Bedroom (21MB free, then 17MB): the margin covers that and the rest.
    private static let margin: UInt64 = 8 << 20

    /// The canvas width when its two bitmaps fit `availableBytes` with the
    /// margin, else `nil` (nothing drawn). 0 means no limit (the Simulator).
    static func pixelWidth(availableBytes: UInt64) -> CGFloat? {
        let pixels = UInt64(width) * UInt64(width * 9 / 16)
        return availableBytes == 0 || pixels * 4 * 2 + margin <= availableBytes ? width : nil
    }

    static func render(
        backdrop: Data, logo: Data?, title: String, context: String, remaining: String?, pixelWidth: CGFloat = 1920
    ) -> Data? {
        let canvas = TopShelfArtworkLayout.canvas
        let pixelHeight = (pixelWidth * 9 / 16).rounded()
        guard let backdropImage = decoded(backdrop, toFill: CGSize(width: pixelWidth, height: pixelHeight)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(
                  data: nil, width: Int(pixelWidth), height: Int(pixelHeight), bitsPerComponent: 8,
                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        // Points of the 1920 layout to pixels; Core Graphics' origin stays
        // bottom-left, so rects go through `flip`.
        cg.scaleBy(x: pixelWidth / canvas.width, y: pixelHeight / canvas.height)
        let flip = { (rect: CGRect) in CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height) }

        let size = CGSize(width: backdropImage.width, height: backdropImage.height)
        let fill = max(canvas.width / size.width, canvas.height / size.height)
        let drawn = CGSize(width: size.width * fill, height: size.height * fill)
        cg.interpolationQuality = .high
        cg.draw(backdropImage, in: flip(CGRect(
            x: (canvas.width - drawn.width) / 2, y: (canvas.height - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        )))

        let wash = CGGradient(
            colorsSpace: space,
            colors: [CGColor(gray: 0, alpha: 0.75), CGColor(gray: 0, alpha: 0)] as CFArray,
            locations: [0, 1]
        )!
        cg.drawLinearGradient(wash, start: .zero, end: CGPoint(x: canvas.width * 0.6, y: 0), options: [])

        if let logo = logo.flatMap(decodedLogo) {
            cg.draw(logo, in: flip(TopShelfArtworkLayout.logoRect(logoSize: CGSize(width: logo.width, height: logo.height))))
        } else {
            drawTitle(title, in: cg, flip: flip)
        }
        drawLine(context, in: TopShelfArtworkLayout.contextRect, font: font(size: 34, weight: 0.3), alpha: 0.9, cg: cg, flip: flip)
        if let remaining {
            drawLine(remaining, in: TopShelfArtworkLayout.remainingRect, font: font(size: 34, weight: 0), alpha: 0.75, cg: cg, flip: flip)
        }

        guard let image = cg.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// The system font at a weight (UIKit's scale: 0 regular, 0.3 semibold,
    /// 0.4 bold), through Core Text.
    private static func font(size: CGFloat, weight: CGFloat) -> CTFont {
        let system = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(system),
            [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func line(_ text: String, font: CTFont, alpha: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha)
        ]))
    }

    /// One line in `rect` (top-left space), its baseline the font's ascent
    /// below the top, truncated with an ellipsis to the rect's width.
    private static func drawLine(
        _ text: String, in rect: CGRect, font: CTFont, alpha: CGFloat, cg: CGContext, flip: (CGRect) -> CGRect
    ) {
        let full = line(text, font: font, alpha: alpha)
        let ellipsis = line("\u{2026}", font: font, alpha: alpha)
        let fitted = CTLineCreateTruncatedLine(full, Double(rect.width), .end, ellipsis) ?? full
        let box = flip(rect)
        cg.textPosition = CGPoint(x: box.minX, y: box.maxY - CTFontGetAscent(font))
        CTLineDraw(fitted, cg)
    }

    /// The name in bold in the logo's box, on the logo's baseline: 72pt,
    /// shrinking to 48pt before it truncates.
    private static func drawTitle(_ title: String, in cg: CGContext, flip: (CGRect) -> CGRect) {
        let box = TopShelfArtworkLayout.logoRect(logoSize: .zero)
        var size: CGFloat = 72
        while size > 48, CTLineGetTypographicBounds(line(title, font: font(size: size, weight: 0.4), alpha: 1), nil, nil, nil) > box.width {
            size -= 4
        }
        let bold = font(size: size, weight: 0.4)
        let height = CTFontGetAscent(bold) + CTFontGetDescent(bold)
        drawLine(title, in: CGRect(x: box.minX, y: box.maxY - height, width: box.width, height: height),
                 font: bold, alpha: 1, cg: cg, flip: flip)
    }

    /// The backdrop decoded just large enough to cover `target`.
    private static func decoded(_ data: Data, toFill target: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0
        else { return nil }
        let fill = min(1, max(target.width / width, target.height / height))
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: ceil(max(width, height) * fill),
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }

    /// The logo decoded no larger than its box, not at its full size.
    private static func decodedLogo(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let box = TopShelfArtworkLayout.logoRect(logoSize: .zero)
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(box.width, box.height),
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }
}

/// The composited art on disk, by `TopShelfEntry.artworkKey`, in the App
/// Group's container, where Sodalite keeps its own. Whether tvOS could read a
/// file in the extension's own container on the device is unknown: the spike
/// that said not drew with UIKit, which kills the extension there.
struct TopShelfArtworkStore {
    static let appGroup = "group.com.imbenjamin.dionysusplayer"

    let directory: URL

    /// `nil` without the App Group (the app's unit-test host).
    static func shared() -> TopShelfArtworkStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup).map {
            TopShelfArtworkStore(directory: $0.appendingPathComponent("Library/Caches/TopShelf", isDirectory: true))
        }
    }

    func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    func existing(for key: String) -> URL? {
        let url = fileURL(for: key)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func write(_ data: Data, for key: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(for: key)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Left while an item renders and removed once it's done, so a render
    /// that killed the extension is found by the next load
    /// (`TopShelfArtworkComposer`).
    func markRendering(_ key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markerURL(for: key).path, contents: nil)
    }

    func clearRendering(_ key: String) {
        try? FileManager.default.removeItem(at: markerURL(for: key))
    }

    func isMarkedRendering(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(for: key).path)
    }

    private func markerURL(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("rendering")
    }

    /// An item whose render killed the extension: left plain from then on.
    func markFailed(_ key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: failedURL(for: key).path, contents: nil)
    }

    func isFailed(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: failedURL(for: key).path)
    }

    private func failedURL(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("failed")
    }

    /// Removes art (and markers) the shelf no longer shows.
    func prune(keeping keys: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keys.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
