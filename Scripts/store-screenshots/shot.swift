// Renders a local HTML file to a PNG at an exact pixel size, via a headless
// WKWebView snapshot. Used by render-store-screenshots.sh to turn gen.py's
// slide HTML into store-ready PNGs — there's no Chrome/Node dependency this
// way, just the system WebKit.
//
// usage: shot <html> <out.png> <width> <height>
import Cocoa
import WebKit

let args = CommandLine.arguments
guard args.count == 5,
      let W = Int(args[3]), let H = Int(args[4]) else {
    FileHandle.standardError.write("usage: shot <html> <out.png> <w> <h>\n".data(using: .utf8)!)
    exit(2)
}
let htmlURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Shooter: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    let out: URL
    let size: NSSize

    init(size: NSSize, out: URL) {
        self.size = size
        self.out = out
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        super.init()
        web.navigationDelegate = self
    }

    func load(_ url: URL) {
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        // let images decode and fonts settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.snap() }
    }

    func webView(_ w: WKWebView, didFail nav: WKNavigation!, withError e: Error) { fail(e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) { fail(e) }

    func fail(_ e: Error) {
        FileHandle.standardError.write("load failed: \(e)\n".data(using: .utf8)!)
        exit(1)
    }

    func snap() {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(origin: .zero, size: size)
        cfg.snapshotWidth = NSNumber(value: Double(size.width))
        web.takeSnapshot(with: cfg) { image, err in
            guard let image = image else {
                FileHandle.standardError.write("snapshot failed: \(String(describing: err))\n".data(using: .utf8)!)
                exit(1)
            }
            // Force exact pixel dimensions regardless of backing scale, into
            // an opaque context: App Store Connect rejects screenshots with an
            // alpha channel (the iPhone Duo spec says so outright), and a
            // `noneSkipLast` image writes as plain RGB.
            let w = Int(self.size.width), h = Int(self.size.height)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            image.draw(in: NSRect(origin: .zero, size: self.size))
            NSGraphicsContext.restoreGraphicsState()
            guard let flat = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(self.out as CFURL, "public.png" as CFString, 1, nil)
            else { exit(1) }
            CGImageDestinationAddImage(dest, flat, nil)
            guard CGImageDestinationFinalize(dest) else { exit(1) }
            exit(0)
        }
    }
}

let shooter = Shooter(size: NSSize(width: W, height: H), out: outURL)
shooter.load(htmlURL)
app.run()
