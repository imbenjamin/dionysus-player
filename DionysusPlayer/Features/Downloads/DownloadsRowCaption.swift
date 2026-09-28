import Foundation

/// The secondary line of a `DownloadsView` list row: its parts, then the
/// row's on-disk size, joined by the same " · " `MediaItem.railSubtitle` uses,
/// plus the sentence VoiceOver reads for it.
///
/// The size is always part of the line, as the iPad grid already showed it. It
/// used to appear only in selection mode, as a trailing column that squeezed
/// the title ("Creature Com…") at exactly the moment the user was choosing what
/// to delete, and was hidden the rest of the time.
struct DownloadsRowCaption: Equatable {
    /// One part: its visible text, and a spoken form where VoiceOver would
    /// misread the visible one ("1h 32m", "54.2 MB"). `nil` means the visible
    /// text reads fine.
    struct Part: Equatable {
        var text: String
        var spoken: String?
    }

    let text: String
    let accessibilityText: String

    /// `nil` when there's nothing to show: no parts and no size. A size of `nil`
    /// or `0` (nothing completed yet) is left out rather than shown as "0 B".
    init?(parts: [Part], sizeBytes: Int64?) {
        var all = parts
        if let sizeBytes, sizeBytes > 0 {
            all.append(Part(
                text: FileSizeText.text(bytes: sizeBytes),
                spoken: FileSizeText.accessibilityText(bytes: sizeBytes)
            ))
        }
        guard !all.isEmpty else { return nil }
        text = all.map(\.text).joined(separator: " \u{00B7} ")
        accessibilityText = all.map { $0.spoken ?? $0.text }.joined(separator: ", ")
    }
}
