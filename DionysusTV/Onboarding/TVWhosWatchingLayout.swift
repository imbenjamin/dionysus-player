/// Who is on Who's Watching?, in order: the accounts already signed in on
/// this Apple TV, most recent first, then everyone else the server lists.
enum TVWhosWatchingLayout {
    struct Lockup: Identifiable, Equatable {
        let user: UserDto
        /// Set for an account signed in here before, which one press signs
        /// in again (`AppState.signIn(rememberedAccount:)`).
        let account: StoredCredentials?
        var id: String { user.id }
    }

    /// A remembered account is shown by the server's own entry when it lists
    /// one, which carries the avatar; a user hidden from the login screen, or
    /// a server that couldn't be asked, by its stored username.
    static func lockups(remembered: [StoredCredentials], listed: [UserDto]) -> [Lockup] {
        var rememberedIDs = Set<String>()
        let first: [Lockup] = remembered.compactMap { account in
            guard let id = account.userID, rememberedIDs.insert(id).inserted else { return nil }
            let user = listed.first { $0.id == id } ?? UserDto(id: id, name: account.username)
            return Lockup(user: user, account: account)
        }
        return first + listed.filter { !rememberedIDs.contains($0.id) }.map { Lockup(user: $0, account: nil) }
    }
}
