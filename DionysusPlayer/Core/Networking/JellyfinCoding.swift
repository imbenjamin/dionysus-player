import Foundation

/// Shared `JSONEncoder`/`JSONDecoder` for talking to Jellyfin.
///
/// Jellyfin's JSON uses PascalCase (`"ProductionYear"`); Swift convention is
/// camelCase (`productionYear`). The two spellings differ only in the case
/// of the first character, so converting between them is an exact,
/// heuristic-free operation — no per-field `CodingKeys` needed anywhere in
/// the DTOs below.
enum JellyfinJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom(CodingKeyCasing.decodingKey)
        decoder.dateDecodingStrategy = .custom(CodingKeyCasing.decodeDate)
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom(CodingKeyCasing.encodingKey)
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

private enum CodingKeyCasing {
    static func decodingKey(_ keys: [CodingKey]) -> CodingKey {
        let key = keys.last!.stringValue
        guard let first = key.first else { return AnyCodingKey(stringValue: key) }
        return AnyCodingKey(stringValue: first.lowercased() + key.dropFirst())
    }

    static func encodingKey(_ keys: [CodingKey]) -> CodingKey {
        let key = keys.last!.stringValue
        guard let first = key.first else { return AnyCodingKey(stringValue: key) }
        return AnyCodingKey(stringValue: first.uppercased() + key.dropFirst())
    }

    static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = fractionalFormatter.date(from: string) { return date }
        if let date = plainFormatter.date(from: string) { return date }
        if let truncated = string.truncatingExcessFractionalSeconds(),
           let date = fractionalFormatter.date(from: truncated) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date format: \(string)")
    }

    /// Standard ISO-8601 with up to millisecond precision.
    static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private extension String {
    /// Jellyfin (backed by .NET) sometimes emits 7-digit fractional seconds
    /// (tick precision); `ISO8601DateFormatter` only understands up to 3.
    func truncatingExcessFractionalSeconds() -> String? {
        guard let dotIndex = firstIndex(of: ".") else { return nil }
        let fractionStart = index(after: dotIndex)
        guard let suffixStart = self[fractionStart...].firstIndex(where: { !$0.isNumber }) else { return nil }
        let fraction = self[fractionStart..<suffixStart]
        guard fraction.count > 3 else { return nil }
        return self[..<fractionStart] + fraction.prefix(3) + self[suffixStart...]
    }
}
