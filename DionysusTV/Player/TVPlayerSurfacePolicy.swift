/// Which surface draws the picture for the engine's current route. Applied on
/// every `$currentAVPlayer` emission, not just the first: an audio reload
/// re-emits, and an escalation can move native to software mid-session.
struct TVPlayerSurface: Equatable {
    let avKitRendersPlayer: Bool
    let engineViewVisible: Bool
}

enum TVPlayerSurfacePolicy {
    static func surface(nativePlayerAvailable: Bool) -> TVPlayerSurface {
        TVPlayerSurface(avKitRendersPlayer: nativePlayerAvailable, engineViewVisible: !nativePlayerAvailable)
    }
}
