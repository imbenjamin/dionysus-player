import UIKit
#if os(tvOS)
import AVKit
#endif

/// What the host knows about the display at load time. On tvOS it feeds
/// AetherEngine's display-criteria handshake; on iOS it is always `.unknown`,
/// which reproduces the engine's defaults, so iOS behaviour is unchanged.
struct DisplayContext: Equatable {
    var matchContentEnabled: Bool
    var panelIsInHDRMode: Bool

    /// The engine's own defaults: matching assumed on, the panel's HDR state
    /// unproven.
    static let unknown = DisplayContext(matchContentEnabled: true, panelIsInHDRMode: false)

    @MainActor
    static func current() -> DisplayContext {
        #if os(tvOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // The key window, not `windows.first`: the player is presented modally,
        // and the spike read Match Content inconsistently from an arbitrary one.
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
                ?? scenes.first?.windows.first else { return .unknown }
        return DisplayContext(
            matchContentEnabled: window.avDisplayManager.isDisplayCriteriaMatchingEnabled,
            // An assertion, not a reading (AetherEngine's `LoadOptions` docs):
            // the engine already ORs in its own `currentEDRHeadroom > 1` readout,
            // which is all this could measure, and on tvOS 27 that property
            // read 1.000 on the test Apple TV while the panel was in HDR10.
            // Nothing here knows better yet; a user setting would.
            panelIsInHDRMode: false
        )
        #else
        return .unknown
        #endif
    }
}
