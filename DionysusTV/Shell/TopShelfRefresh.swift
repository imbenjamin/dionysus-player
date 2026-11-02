import TVServices

/// Keeps the Top Shelf current (M6). The extension reads the default Apple
/// TV profile's keychain whichever profile is active (spike, 2026-10-14), so
/// the app mirrors its session into the shared keychain each time it settles
/// (`TopShelfSession`) and the shelf shows whoever last used Dionysus. tvOS
/// is also asked to reload the shelf after what changes it: a playback
/// session ending and a watched toggle. It refreshes on its own schedule too.
enum TopShelfRefresh {
    /// Replaced in tests.
    @MainActor static var notify: @MainActor () -> Void = { TVTopShelfContentProvider.topShelfContentDidChange() }

    @MainActor static func contentChanged() { notify() }

    /// Called when the app's phase settles and when it becomes active: the
    /// session signed in, or none (signed out, server setup). Nothing while
    /// the session is still restoring, so a launch doesn't blank the shelf.
    @MainActor static func appStateChanged(
        isRestoringSession: Bool, isSignedIn: Bool, server: ServerConfiguration?, credentials: StoredCredentials?
    ) {
        guard !isRestoringSession else { return }
        let session = isSignedIn
            ? TopShelfSession.make(
                server: server, credentials: credentials,
                deviceID: DeviceIdentity.deviceID, deviceName: DeviceIdentity.deviceName
            )
            : nil
        TopShelfSessionMirror.write(session)
        notify()
    }
}
