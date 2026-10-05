import SwiftUI

/// A long bundled text (the license, the privacy policy) on the Apple TV,
/// where a scroll view moves only with focus: the text is cut into
/// paragraphs, each focusable, so Up and Down scroll through it.
struct TVTextPageView: View {
    let title: LocalizedStringKey
    let paragraphs: [AttributedString]
    @FocusState private var focused: Int?

    /// The bundled file split on blank lines, with the privacy policy's
    /// headers and bullets styled as iOS's `PrivacyPolicyView` styles them.
    static func paragraphs(resource: String, extension ext: String?, markdown: Bool, bundle: Bundle = .main) -> [AttributedString] {
        guard let url = bundle.url(forResource: resource, withExtension: ext),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return [AttributedString(String(localized: "This text is unavailable."))]
        }
        return paragraphs(of: raw, markdown: markdown)
    }

    static func paragraphs(of raw: String, markdown: Bool) -> [AttributedString] {
        raw.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { markdown ? styled($0) : AttributedString($0) }
    }

    private static func styled(_ block: String) -> AttributedString {
        var result = AttributedString()
        let lines = block.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var content = line.trimmingCharacters(in: .whitespaces)
            var headerLevel = 0
            while content.hasPrefix("#") { headerLevel += 1; content.removeFirst() }
            content = content.trimmingCharacters(in: .whitespaces)
            var prefix = ""
            if content.hasPrefix("- ") || content.hasPrefix("* ") { prefix = "•  "; content.removeFirst(2) }
            var parsed = (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(content)
            if headerLevel > 0 { parsed.font = headerLevel <= 1 ? .title2.bold() : .headline }
            result += AttributedString(prefix) + parsed
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(A11yID.TV.Profile.textPage)
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(focused == index ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 16))
                        .focusable()
                        .focused($focused, equals: index)
                }
            }
            .padding(.horizontal, 240)
            .padding(.vertical, 80)
        }
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .defaultFocus($focused, 0)
    }
}
