/// Where choosing a user on Who's Watching? leads. Quick Connect first,
/// because typing a password with a Siri Remote is the worst part of any TV
/// sign-in; the password stays one press away on its screen.
enum TVSignInRoute: Equatable {
    case signInNow
    case quickConnect
    case password

    static func forUser(_ user: UserDto, quickConnectAvailable: Bool) -> TVSignInRoute {
        if user.hasPassword == false { return .signInNow }
        return quickConnectAvailable ? .quickConnect : .password
    }
}
