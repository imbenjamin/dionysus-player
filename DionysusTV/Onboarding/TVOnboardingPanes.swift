import SwiftUI

/// The onboarding composition from the prototype: an 800pt brand pane on the
/// left, the task on the right, ending 140pt from the screen's edge. Both are
/// vertically centred.
struct TVOnboardingPanes<Brand: View, Task: View>: View {
    @ViewBuilder var brand: Brand
    @ViewBuilder var task: Task

    var body: some View {
        HStack(spacing: 60) {
            brand
                .frame(width: 800)
                .frame(maxHeight: .infinity)
            task
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.trailing, 140)
        }
        .ignoresSafeArea()
    }
}
