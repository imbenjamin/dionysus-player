import Foundation

/// Human-readable "1.24 GB"-style text for a byte count, and its VoiceOver
/// counterpart spelling out the unit — the shared formatting convention for
/// every *new* place a live byte count shows up in the downloads UI: the
/// Advanced Options size estimate, per-row sizes during bulk-delete
/// selection, and the delete confirmation's total.
///
/// A couple of near-identical copies of this same formula already existed
/// before this type did — `DownloadedDetailTabsView.fileSizeAccessibilityText`
/// and `DownloadedInfoMetadataRow.spokenFileSize(_:)` — but neither was
/// migrated to call through here: both sit inside already-shipped, working
/// views, and `spokenFileSize(_:)` specifically doubles as the fallback case
/// for *any* unrecognized accessibility badge, not just a byte count, so
/// it isn't a clean drop-in replacement. New call sites should use this
/// type; the older two aren't wrong, just not worth the risk of touching
/// for no behavioral gain.
enum FileSizeText {
    static func text(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Parses `text(bytes:)`'s own output rather than reimplementing
    /// `ByteCountFormatter`'s unit-selection/rounding, so the two can never
    /// drift out of agreement — VoiceOver otherwise reads "2.44 GB" letter
    /// by letter ("two point four four G B") rather than as a real unit.
    static func accessibilityText(bytes: Int64) -> String {
        let formatted = text(bytes: bytes)
        guard let spaceIndex = formatted.lastIndex(of: " ") else { return formatted }
        let number = formatted[..<spaceIndex]
        let unit = formatted[formatted.index(after: spaceIndex)...]
        let spokenUnit: String?
        switch unit {
        case "byte", "bytes": spokenUnit = String(localized: "bytes")
        case "KB": spokenUnit = String(localized: "kilobytes")
        case "MB": spokenUnit = String(localized: "megabytes")
        case "GB": spokenUnit = String(localized: "gigabytes")
        case "TB": spokenUnit = String(localized: "terabytes")
        case "PB": spokenUnit = String(localized: "petabytes")
        default: spokenUnit = nil
        }
        guard let spokenUnit else { return formatted }
        return "\(number) \(spokenUnit)"
    }
}
