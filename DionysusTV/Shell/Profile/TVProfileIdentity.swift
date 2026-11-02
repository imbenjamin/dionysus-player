/// Who the sidebar's Profile entry shows. The live user once sign-in has
/// answered; before that (a launch resumed from cache while the server is
/// unreachable, see `AppState.start()`), the stored account, with no image tag
/// so the avatar shows its monogram rather than fetching.
enum TVProfileIdentity {
    static func user(currentUser: UserDto?, credentials: StoredCredentials?) -> UserDto? {
        if let currentUser { return currentUser }
        guard let credentials, let id = credentials.userID else { return nil }
        return UserDto(id: id, name: credentials.username, hasPassword: nil, primaryImageTag: nil)
    }
}
