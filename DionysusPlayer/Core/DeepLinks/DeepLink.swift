import Foundation

/// A `dionysus://` link (#406): `dionysus://<destination>[/<id>][?<parameters>]`.
///
/// Links are an API-only capability, for debugging, UI tests and the Apple
/// TV's Top Shelf: nothing in the app makes, copies or shares one (Benjamin,
/// 2026-11-11). They navigate and play, never change data, so there is no
/// destination that signs in or out, deletes, or marks anything. The grammar,
/// the use cases and the fallbacks are in
/// `docs/superpowers/specs/2026-11-11-deep-linking-design.md`.
///
/// Parsing is pure and lenient where it can be: an unknown parameter is
/// ignored (a newer link still opens in an older build), and a known one that
/// can't be read is dropped and recorded in `issues`, so the app can apply
/// the rest and say what it left out. Only a link with no usable destination
/// is refused (`init?(url:)` returns nil). Whether the item, time, chapter,
/// version or track exists is for whoever applies the link, which has the
/// item in hand.
///
/// The Top Shelf's links (`item`/`play` with `server=`) parse as they always
/// have: a shelf on someone's Apple TV can hold URLs an older version built.
struct DeepLink: Equatable, Sendable {
    static let scheme = "dionysus"

    var destination: Destination
    /// `ServerConfiguration.id` of the server the link was made for; nil
    /// applies it to whichever server is signed in.
    var serverID: String?
    /// The Jellyfin user the link was made for; nil applies it to whoever is
    /// signed in.
    var userID: String?
    /// What the link asked for that couldn't be read, in the order found.
    /// Never part of a built URL.
    var issues: [Issue] = []

    init(_ destination: Destination, serverID: String? = nil, userID: String? = nil) {
        self.destination = destination
        self.serverID = serverID
        self.userID = userID
    }

    enum Destination: Equatable, Sendable {
        case home
        case search(query: String?)
        /// iOS only; the Apple TV falls back to Home.
        case downloads
        /// Profile, or a page within it (`["playback", "advanced"]`); which
        /// paths exist is each platform's call.
        case profile(path: [String])
        /// Fills the code on the Account page's approval screen; never submits it.
        case quickConnectApproval(code: String?)
        case library(id: String, options: LibraryOptions)
        case item(id: String, options: ItemOptions)
        /// A downloaded item's own page (iOS), which works offline.
        case downloaded(id: String)
        case play(id: String, options: PlaybackOptions)
        /// Server setup with the address filled in, not connected. Parsed in
        /// DEBUG builds only: a web page mustn't point the app at a server.
        case serverSetup(address: String)
    }

    struct LibraryOptions: Equatable, Sendable {
        enum Filter: String, Sendable { case favorites, unwatched, watched }
        var sort: CollectionSortField?
        var order: CollectionSortOrder?
        var genre: String?
        var studio: String?
        var filter: Filter?
    }

    struct ItemOptions: Equatable, Sendable {
        enum Section: String, Sendable { case cast, chapters, details, similar }
        /// A season's id, or its number as shown.
        var season: String?
        var section: Section?
    }

    struct PlaybackOptions: Equatable, Sendable {
        enum Start: Equatable, Sendable {
            case time(TimeInterval)
            /// 1-based, as the chapter list shows it.
            case chapter(Int)
        }
        enum Subtitle: Equatable, Sendable {
            case off
            /// Jellyfin's `MediaStream.Index`.
            case stream(Int)
        }
        enum DecisionMode: String, Sendable { case direct, transcode }

        var start: Start?
        var mediaSourceID: String?
        /// Jellyfin's `MediaStream.Index`.
        var audioStreamIndex: Int?
        var subtitle: Subtitle?
        var showsStats = false
        /// iOS: play the downloaded copy when there is one.
        var prefersDownload = false
        /// Play `id` with the rest of this playlist after it, as tapping its
        /// row does.
        var playlistID: String?
        /// DEBUG builds only: for this session, instead of the stored
        /// preference.
        var decisionMode: DecisionMode?
        /// DEBUG builds only, in bits per second.
        var maxBitrate: Int?
    }

    enum Issue: Equatable, Sendable {
        case unreadableStartTime
        case unreadableChapter
        case unreadableAudio
        case unreadableSubtitle
        case unknownSort
        case unknownOrder
        case unknownFilter
        case unknownSection
        case unknownMode
        case unreadableBitrate
    }
}

// MARK: - Parsing

extension DeepLink {
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let host = url.host()?.lowercased(), !host.isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var query = Query(items: components.queryItems ?? [])

        let destination: Destination
        switch host {
        case "home":
            guard path.isEmpty else { return nil }
            destination = .home
        case "search":
            guard path.isEmpty else { return nil }
            destination = .search(query: query.string("q"))
        case "downloads":
            guard path.isEmpty else { return nil }
            destination = .downloads
        case "profile":
            guard path.count <= 2 else { return nil }
            destination = .profile(path: path)
        case "quickconnect":
            guard path == ["approve"] else { return nil }
            destination = .quickConnectApproval(code: query.string("code"))
        case "library":
            guard let id = Self.singleID(path) else { return nil }
            destination = .library(id: id, options: Self.libraryOptions(&query))
        case "item":
            guard let id = Self.singleID(path) else { return nil }
            destination = .item(id: id, options: Self.itemOptions(&query))
        case "downloaded":
            guard let id = Self.singleID(path) else { return nil }
            destination = .downloaded(id: id)
        case "play":
            guard let id = Self.singleID(path) else { return nil }
            destination = .play(id: id, options: Self.playbackOptions(&query))
        #if DEBUG
        case "server":
            guard path.isEmpty, let address = query.string("url") else { return nil }
            destination = .serverSetup(address: address)
        #endif
        default:
            return nil
        }
        self.init(destination, serverID: query.string("server"), userID: query.string("user"))
        issues = query.issues
    }

    private static func singleID(_ path: [String]) -> String? {
        path.count == 1 ? path[0] : nil
    }

    private static func libraryOptions(_ query: inout Query) -> LibraryOptions {
        var options = LibraryOptions()
        options.sort = query.value("sort", issue: .unknownSort) { sortFields[$0] }
        options.order = query.value("order", issue: .unknownOrder) { sortOrders[$0] }
        options.genre = query.string("genre")
        options.studio = query.string("studio")
        options.filter = query.value("filter", issue: .unknownFilter, LibraryOptions.Filter.init(rawValue:))
        return options
    }

    private static func itemOptions(_ query: inout Query) -> ItemOptions {
        var options = ItemOptions()
        options.season = query.string("season")
        options.section = query.value("section", issue: .unknownSection, ItemOptions.Section.init(rawValue:))
        return options
    }

    private static func playbackOptions(_ query: inout Query) -> PlaybackOptions {
        var options = PlaybackOptions()
        if let time = query.value("t", issue: .unreadableStartTime, seconds(from:)) {
            options.start = .time(time)
        } else if query.string("t") == nil,
                  let chapter = query.value("chapter", issue: .unreadableChapter, { Int($0).flatMap { $0 > 0 ? $0 : nil } }) {
            options.start = .chapter(chapter)
        }
        options.mediaSourceID = query.string("source")
        options.audioStreamIndex = query.value("audio", issue: .unreadableAudio, streamIndex(from:))
        options.subtitle = query.value("subtitle", issue: .unreadableSubtitle) { text in
            text == "off" ? .off : streamIndex(from: text).map { .stream($0) }
        }
        options.showsStats = query.flag("stats")
        options.prefersDownload = query.flag("offline")
        options.playlistID = query.string("playlist")
        #if DEBUG
        options.decisionMode = query.value("mode", issue: .unknownMode, PlaybackOptions.DecisionMode.init(rawValue:))
        options.maxBitrate = query.value("bitrate", issue: .unreadableBitrate) { Int($0).flatMap { $0 > 0 ? $0 : nil } }
        #endif
        return options
    }

    private static func streamIndex(from text: String) -> Int? {
        guard text.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(text)
    }

    /// A start time: seconds (`90`, `90.5`) or `[h:]m:ss` (`1:30`,
    /// `1:02:03`). Nil for anything else, negative times included.
    static func seconds(from text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            let digits = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(digits.count),
                  digits.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) })
            else { return nil }
            return TimeInterval(parts[0])
        case 2, 3:
            guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
                  parts.dropFirst().allSatisfy({ $0.count == 2 })
            else { return nil }
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
            return TimeInterval(numbers.reduce(0) { $0 * 60 + $1 })
        default:
            return nil
        }
    }

    private static let sortFields: [String: CollectionSortField] = [
        "title": .title, "dateAdded": .dateAdded, "releaseDate": .releaseDate,
    ]
    private static let sortOrders: [String: CollectionSortOrder] = [
        "asc": .ascending, "desc": .descending,
    ]

    /// Query items by name (the first of a repeated name wins), with an empty
    /// value read as absent, and the issues met while reading them.
    private struct Query {
        let items: [URLQueryItem]
        var issues: [Issue] = []

        func string(_ name: String) -> String? {
            guard let value = items.first(where: { $0.name == name })?.value, !value.isEmpty else { return nil }
            return value
        }

        func flag(_ name: String) -> Bool {
            ["1", "true", "yes"].contains(string(name)?.lowercased())
        }

        /// The parameter read by `read`; an unreadable value is recorded as `issue`.
        mutating func value<T>(_ name: String, issue: Issue, _ read: (String) -> T?) -> T? {
            guard let text = string(name) else { return nil }
            guard let value = read(text) else {
                issues.append(issue)
                return nil
            }
            return value
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - Building

extension DeepLink {
    /// The link as a URL, the only way code builds one (the Top Shelf, tests),
    /// so a link made here always parses back to itself.
    var url: URL {
        var host: String
        var path: [String] = []
        var query: [(String, String?)] = []

        switch destination {
        case .home:
            host = "home"
        case .search(let text):
            host = "search"
            query.append(("q", text))
        case .downloads:
            host = "downloads"
        case .profile(let pages):
            host = "profile"
            path = pages
        case .quickConnectApproval(let code):
            host = "quickconnect"
            path = ["approve"]
            query.append(("code", code))
        case .library(let id, let options):
            host = "library"
            path = [id]
            query += [
                ("sort", options.sort.flatMap { sort in Self.sortFields.first { $0.value == sort }?.key }),
                ("order", options.order.flatMap { order in Self.sortOrders.first { $0.value == order }?.key }),
                ("genre", options.genre), ("studio", options.studio), ("filter", options.filter?.rawValue),
            ]
        case .item(let id, let options):
            host = "item"
            path = [id]
            query += [("season", options.season), ("section", options.section?.rawValue)]
        case .downloaded(let id):
            host = "downloaded"
            path = [id]
        case .play(let id, let options):
            host = "play"
            path = [id]
            switch options.start {
            case .time(let seconds):
                query.append(("t", seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)))
            case .chapter(let number):
                query.append(("chapter", String(number)))
            case nil:
                break
            }
            let subtitle: String? = switch options.subtitle {
            case .off: "off"
            case .stream(let index): String(index)
            case nil: nil
            }
            query += [
                ("source", options.mediaSourceID),
                ("audio", options.audioStreamIndex.map(String.init)),
                ("subtitle", subtitle),
                ("stats", options.showsStats ? "1" : nil),
                ("offline", options.prefersDownload ? "1" : nil),
                ("playlist", options.playlistID),
                ("mode", options.decisionMode?.rawValue),
                ("bitrate", options.maxBitrate.map(String.init)),
            ]
        case .serverSetup(let address):
            host = "server"
            query.append(("url", address))
        }
        query += [("server", serverID), ("user", userID)]

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        components.path = path.isEmpty ? "" : "/" + path.joined(separator: "/")
        // Encoded by hand: `URLQueryItem` leaves `&`, `=` and `+` alone in a
        // value, so a genre such as "Sci-Fi & Fantasy" would split in two.
        let encoded = query.compactMap { name, value in
            value.map { "\(name)=\($0.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? $0)" }
        }
        components.percentEncodedQuery = encoded.isEmpty ? nil : encoded.joined(separator: "&")
        return components.url!
    }

    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
}
