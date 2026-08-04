import XCTest
@testable import Dionysus

/// `JellyfinJSON` is the one piece of coding-adjacent magic in the app —
/// automatic PascalCase↔camelCase conversion, plus a date decoder that has
/// to cope with Jellyfin/.NET emitting inconsistent fractional-second
/// precision. If this silently breaks, every DTO decode breaks with it, so
/// it's worth pinning down independently of any specific DTO.
final class JellyfinCodingTests: XCTestCase {
    private struct Fixture: Codable, Equatable {
        var itemName: String
        var releaseDate: Date
    }

    // MARK: Key casing

    func test_decoder_convertsPascalCaseKeysToCamelCase() throws {
        let json = """
        {"ItemName":"Alien","ReleaseDate":"1979-05-25T00:00:00.000Z"}
        """.data(using: .utf8)!

        let fixture = try JellyfinJSON.decoder.decode(Fixture.self, from: json)
        XCTAssertEqual(fixture.itemName, "Alien")
    }

    func test_encoder_convertsCamelCaseKeysToPascalCase() throws {
        let fixture = Fixture(itemName: "Alien", releaseDate: Date(timeIntervalSince1970: 0))
        let data = try JellyfinJSON.encoder.encode(fixture)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["ItemName"] as? String, "Alien")
        XCTAssertNotNil(object["ReleaseDate"])
        XCTAssertNil(object["itemName"])
    }

    // MARK: Date decoding

    func test_decodeDate_plainISO8601WithoutFractionalSeconds() throws {
        let json = #"{"ItemName":"x","ReleaseDate":"1979-05-25T12:00:00Z"}"#.data(using: .utf8)!
        let fixture = try JellyfinJSON.decoder.decode(Fixture.self, from: json)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: fixture.releaseDate), 1979)
    }

    func test_decodeDate_millisecondPrecision() throws {
        let json = #"{"ItemName":"x","ReleaseDate":"1979-05-25T12:00:00.123Z"}"#.data(using: .utf8)!
        let fixture = try JellyfinJSON.decoder.decode(Fixture.self, from: json)
        XCTAssertEqual(fixture.releaseDate.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.123, accuracy: 0.0005)
    }

    /// .NET/Jellyfin sometimes emits tick-precision (7-digit) fractional
    /// seconds, which `ISO8601DateFormatter` can't parse directly — the
    /// decoder is expected to truncate to milliseconds and retry.
    func test_decodeDate_sevenDigitFractionalSecondsIsTruncatedAndParsed() throws {
        let json = #"{"ItemName":"x","ReleaseDate":"1979-05-25T12:00:00.1234567Z"}"#.data(using: .utf8)!
        let fixture = try JellyfinJSON.decoder.decode(Fixture.self, from: json)
        // Should land on the same instant as the equivalent millisecond value.
        let expectedMillis = try JellyfinJSON.decoder.decode(
            Fixture.self,
            from: #"{"ItemName":"x","ReleaseDate":"1979-05-25T12:00:00.123Z"}"#.data(using: .utf8)!
        )
        XCTAssertEqual(fixture.releaseDate, expectedMillis.releaseDate)
    }

    func test_decodeDate_unrecognizedFormatThrows() {
        let json = #"{"ItemName":"x","ReleaseDate":"not-a-date"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JellyfinJSON.decoder.decode(Fixture.self, from: json))
    }

    // MARK: BaseItemKind open-ended enum

    private struct KindWrapper: Codable { var type: BaseItemKind }

    func test_baseItemKind_knownValueDecodes() throws {
        let wrapper = try JSONDecoder().decode(KindWrapper.self, from: #"{"type":"Movie"}"#.data(using: .utf8)!)
        XCTAssertEqual(wrapper.type, .movie)
    }

    func test_baseItemKind_unrecognizedValueFallsBackToUnknownInsteadOfThrowing() throws {
        let wrapper = try JSONDecoder().decode(KindWrapper.self, from: #"{"type":"SomeFuturePluginType"}"#.data(using: .utf8)!)
        XCTAssertEqual(wrapper.type, .unknown)
    }
}
