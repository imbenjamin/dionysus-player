import Foundation

/// What the Top Shelf's actions open (M6): `dionysus://item/<id>?server=<id>`
/// for a title's detail page, `dionysus://play/<id>?server=<id>` to play it
/// over that page. The server is `ServerConfiguration.id`, so a link built
/// for another server is never applied to this one.
struct TVDeepLink: Equatable {
    enum Action: String { case item, play }

    static let scheme = "dionysus"

    var action: Action
    var itemID: String
    var serverID: String

    init(action: Action, itemID: String, serverID: String) {
        self.action = action
        self.itemID = itemID
        self.serverID = serverID
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let host = url.host(), let action = Action(rawValue: host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let serverID = components.queryItems?.first(where: { $0.name == "server" })?.value, !serverID.isEmpty
        else { return nil }
        let itemID = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !itemID.isEmpty, !itemID.contains("/") else { return nil }
        self.init(action: action, itemID: itemID, serverID: serverID)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = action.rawValue
        components.path = "/" + itemID
        components.queryItems = [URLQueryItem(name: "server", value: serverID)]
        return components.url!
    }
}
