import SwiftUI

/// Pill-style top navigation for the Home screen: Movies / Series /
/// Collections. Deliberately lighter than the bottom tab bar — selected
/// pill takes the brand primary as a fill, unselected pills have a subtle
/// chrome to remain tappable-looking without competing with the tab bar.
struct TopMenuBar: View {
    @Binding var selection: HomeCategory

    var body: some View {
        HStack(spacing: 8) {
            ForEach(HomeCategory.allCases) { category in
                let isSelected = selection == category
                Button {
                    withAnimation(.snappy) { selection = category }
                } label: {
                    Text(category.rawValue)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            Capsule(style: .continuous)
                                .fill(isSelected ? AnyShapeStyle(Color.dionysusPrimary) : AnyShapeStyle(.quaternary))
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    TopMenuBar(selection: .constant(.movies))
        .padding()
}
