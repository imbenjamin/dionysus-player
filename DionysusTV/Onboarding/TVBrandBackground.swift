import SwiftUI

/// The onboarding flow's brand ground: the iOS mesh colours, drawn statically.
struct TVBrandBackground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.55, 0], [1, 0], [0, 0.45], [0.5, 0.5], [1, 0.55], [0, 1], [0.5, 1], [1, 1]],
                colors: [
                    .dionysusMagenta, Color(red: 0.55, green: 0.02, blue: 0.26), .dionysusBurgundy,
                    Color(red: 0.62, green: 0.16, blue: 0.10), .dionysusMagenta, Color(red: 0.55, green: 0.02, blue: 0.26),
                    .dionysusBurgundy, Color(red: 0.07, green: 0, blue: 0.04), Color(red: 0.07, green: 0, blue: 0.04)
                ]
            )
            .ignoresSafeArea()
            content
        }
    }
}
