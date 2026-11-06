import XCTest
@testable import Dionysus

/// What `DownloadManager.enqueue` fetches beside the video for offline use:
/// text subtitles and the source's fonts. These ran only inside the UI
/// download journey, which checks none of them. The video transfer itself is
/// stubbed out (`startVideoDownloadOverride`); every other fetch answers from
/// `MockURLProtocol`.
@MainActor
final class DownloadManagerExtrasTests: XCTestCase {
    private let baseURL = URL(string: "https://jellyfin.example.com")!
    private let itemID = "extras-movie"
    private var manager: DownloadManager?

    override func tearDown() async throws {
        manager?.delete(itemID: itemID)
        manager = nil
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    /// Enqueues a movie whose source carries `streams` and `attachments`,
    /// answering each request with `answer` (404 for anything it returns
    /// `nil` for), and returns the stored row once the extras are in.
    private func enqueue(
        subtitles: [MediaStream],
        attachments: [MediaAttachment] = [],
        answer: @escaping @Sendable (String) -> (Int, Data)?
    ) async throws -> DownloadedItem {
        MockURLProtocol.requestHandler = { request in
            let (status, body) = answer(request.url?.path ?? "") ?? (404, Data())
            return MockURLProtocol.jsonResponse(for: request, status: status, body: body)
        }
        let store = DownloadTestHelpers.makeInMemoryStore()
        let manager = DownloadManager(
            store: store,
            startVideoDownloadOverride: { _, _, _ in },
            fetchSession: MockURLProtocol.makeSession()
        )
        self.manager = manager
        let client = JellyfinAPIClient(baseURL: baseURL, accessToken: "tok", session: MockURLProtocol.makeSession())
        let dto = BaseItemDto(id: itemID, name: "Extras", type: .movie)
        let item = MediaItem(dto: dto, images: ImageURLBuilder(baseURL: baseURL, accessToken: "tok"))
        let source = MediaSourceInfo(
            id: "src-1",
            mediaStreams: [MediaStream(index: 0, type: "Video", codec: "h264", width: 1920, height: 1080)] + subtitles,
            mediaAttachments: attachments
        )
        try await manager.enqueue(
            item: item, mediaSource: source, audioTrack: nil, subtitleTracks: subtitles,
            resolution: .hd1080p, preset: .normal, client: client, userID: "user-1"
        )
        return try XCTUnwrap(store.item(itemID: itemID))
    }

    func test_textSubtitles_areDownloadedBesideTheVideo_bitmapOnesListedAsSkipped() async throws {
        let srt = MediaStream(index: 2, type: "Subtitle", codec: "subrip", language: "eng", displayTitle: "English", isForced: true)
        let pgs = MediaStream(index: 3, type: "Subtitle", codec: "PGSSUB", language: "jpn", displayTitle: "Japanese (PGS)")
        let cue = Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8)

        let row = try await enqueue(subtitles: [srt, pgs]) { path in
            path.hasSuffix("/Subtitles/2/Stream.srt") ? (200, cue) : nil
        }

        XCTAssertEqual(row.subtitleFiles.map(\.index), [2], "The text track only")
        let file = try XCTUnwrap(row.subtitleFiles.first)
        XCTAssertEqual(file.language, "eng")
        XCTAssertTrue(file.isForced)
        XCTAssertEqual(try Data(contentsOf: DownloadFileStore.url(forRelativePath: file.relativePath)), cue)
        XCTAssertEqual(row.skippedSubtitleTracks, ["Japanese (PGS)"], "A bitmap track can't be downloaded, and says so")
    }

    /// A subtitle the server won't serve is dropped, not saved: the error
    /// body written as a `.srt` would be offered as a track and show garbage.
    func test_aSubtitleTheServerRefuses_isNotSaved() async throws {
        let srt = MediaStream(index: 2, type: "Subtitle", codec: "subrip", language: "eng", displayTitle: "English")

        let row = try await enqueue(subtitles: [srt]) { path in
            path.hasSuffix("/Subtitles/2/Stream.srt") ? (404, Data("<html>Not Found</html>".utf8)) : nil
        }

        XCTAssertTrue(row.subtitleFiles.isEmpty, "A 404 isn't a subtitle")
    }

    func test_fontAttachments_areDownloaded_otherAttachmentsAreNot() async throws {
        let font = Data("OTTO-font-bytes".utf8)
        let attachments = [
            MediaAttachment(index: 0, codec: "mjpeg", fileName: "cover.jpg", mimeType: "image/jpeg"),
            MediaAttachment(index: 1, codec: "ttf", fileName: "Title.ttf", mimeType: "application/x-truetype-font"),
            MediaAttachment(index: 2, codec: "ttf", fileName: "Missing.ttf", mimeType: "application/x-truetype-font"),
        ]

        let row = try await enqueue(subtitles: [], attachments: attachments) { path in
            if path.hasSuffix("/Attachments/1") { return (200, font) }
            if path.hasSuffix("/Attachments/0") { return (200, Data("jpeg".utf8)) }
            return nil
        }

        XCTAssertEqual(row.fontFiles.map(\.fileName), ["Title.ttf"], "The font that answered; not the cover, not the 404")
        let file = try XCTUnwrap(row.fontFiles.first)
        XCTAssertEqual(try Data(contentsOf: DownloadFileStore.url(forRelativePath: file.relativePath)), font)
    }
}
