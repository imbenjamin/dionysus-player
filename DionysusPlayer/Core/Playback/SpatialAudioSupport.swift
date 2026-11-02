import AetherEngine

/// Whether this device and build can render a format as Spatial Audio, so the
/// settings show only where they would do something.
enum SpatialAudioSupport {
    /// OS 26 or later (AetherEngine's APAC encoder; iOS's floor is 18) and the
    /// component compiled in.
    static func isOffered(_ format: SpatialAudioFormat) -> Bool {
        guard #available(iOS 26, tvOS 26, *) else { return false }
        return isBuiltIn(format)
    }

    /// The package traits `Packages/AetherEngineWithObjectAudio` switches on.
    /// Without one, `objectAudioRendering` is a no-op for that format.
    static func isBuiltIn(_ format: SpatialAudioFormat) -> Bool {
        switch format {
        case .dolbyAtmos: return AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn
        case .dtsX: return AetherEngine.OptionalComponent.dtsxObjectAudio.isBuiltIn
        }
    }
}
