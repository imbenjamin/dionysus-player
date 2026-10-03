import Foundation

/// The grid's alphabet bar: which letter a title sits under, and the first
/// item for each letter.
///
/// The grid is ordered by Jellyfin's sort name, which drops a leading
/// article, so the letter does the same. Anything that isn't A–Z once
/// accents are folded (digits, punctuation, other scripts, an empty name)
/// goes under "#", so no title is left without a letter.
enum TVAlphabetIndex {
    static let letters: [Character] = ["#"] + Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private static let articles = ["the ", "a ", "an "]

    static func letter(for name: String) -> Character {
        var title = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let article = articles.first(where: title.hasPrefix) {
            let rest = title.dropFirst(article.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { title = rest }
        }
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).uppercased()
        // "Ø" doesn't decompose; map the few such letters by hand.
        let first = folded.first.map { Self.stroked[$0] ?? $0 }
        guard let first, first.isASCII, first.isLetter else { return "#" }
        return first
    }

    private static let stroked: [Character: Character] = ["Ø": "O", "Ł": "L", "Đ": "D", "Æ": "A", "Œ": "O"]

    /// The first item, in list order, under each letter.
    static func firstItemIDs(_ items: [(id: String, name: String)]) -> [Character: String] {
        var index: [Character: String] = [:]
        for item in items {
            let letter = letter(for: item.name)
            if index[letter] == nil { index[letter] = item.id }
        }
        return index
    }

    /// The system index's titles: the letters that have a title under them,
    /// in the bar's order. `nil` with fewer than two, where there's nothing
    /// to jump between.
    static func indexTitles(_ names: [String]) -> [String]? {
        let present = Set(names.map(letter(for:)))
        let titles = letters.filter(present.contains).map(String.init)
        return titles.count > 1 ? titles : nil
    }

    /// Where the first title under an index title sits in the list.
    static func firstIndex(under title: String, in names: [String]) -> Int? {
        names.firstIndex { String(letter(for: $0)) == title }
    }
}
