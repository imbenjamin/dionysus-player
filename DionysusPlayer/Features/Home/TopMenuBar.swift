import SwiftUI

/// Disney+-style top navigation for the Home screen: Movies / Series /
/// Collections.
struct TopMenuBar: View {
    @Binding var selection: HomeCategory

    var body: some View {
        HStack(spacing: 24) {
            ForEach(HomeCategory.allCases) { category in
                Button {
                    withAnimation(.snappy) { selection = category }
                } label: {
                    Text(category.rawValue)
                        .font(.subheadline.weight(selection == category ? .bold : .regular))
                        .foregroundStyle(selection == category ? Color.primary : Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    TopMenuBar(selection: .constant(.movies))
        .padding()
}
