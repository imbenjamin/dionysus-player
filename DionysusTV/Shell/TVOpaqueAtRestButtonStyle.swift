import SwiftUI

/// The system's button, with a resting platter that stays readable under
/// Reduce Transparency (M5). There tvOS draws a default button's resting
/// platter opaque light grey under the label's white, about 2:1; the tint
/// darkens it to the grey Apple's Settings rows rest on, and the label is
/// made primary since the tint would colour it too. Focused, the button is
/// the system's white platter as before. Set once at the root, so a button
/// with a style of its own (`.card`, `.plain`, the sidebar's) is untouched,
/// and scoped to buttons rather than a root tint, which spinners also follow.
struct TVOpaqueAtRestButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OpaqueAtRest(configuration: configuration)
    }

    static let restingPlatter = Color(white: 0.28)

    private struct OpaqueAtRest: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        var body: some View {
            if reduceTransparency {
                Button(configuration)
                    .tint(TVOpaqueAtRestButtonStyle.restingPlatter)
                    .foregroundStyle(.primary)
            } else {
                Button(configuration)
            }
        }
    }
}
