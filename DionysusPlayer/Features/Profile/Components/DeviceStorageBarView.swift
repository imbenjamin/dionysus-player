import SwiftUI

/// iOS Settings' "iPhone Storage" segmented bar, reduced to the three
/// buckets this app can actually speak to (see `DeviceStorageBreakdown`'s
/// doc comment for why it stops there instead of a full per-app/media-type
/// breakdown).
struct DeviceStorageBarView: View {
    let breakdown: DeviceStorageBreakdown
    /// e.g. "Free space for about 12 movies or 50 TV episodes at the
    /// current download settings." — rendered inside this same card rather
    /// than the section footer, per an explicit ask that it read as
    /// prominently as the graph itself rather than as fine print below it.
    /// `nil` omits the row entirely (`DownloadsSettingsView` only ever
    /// passes a value once it has a real `DeviceStorageBreakdown` to
    /// compute it from).
    let freeSpaceEstimateText: String?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var appUsedText: String {
        Self.byteFormatter.string(fromByteCount: breakdown.appUsed)
    }

    /// Whole-GB, rounded *up* — e.g. 255.42 GB actual reads as "256 GB",
    /// not "255 GB". Matches how the header's two figures are meant to
    /// read together ("X GB of Y GB Used"): rounding one down and the
    /// other up (or to nearest) can make "used" appear to exceed "total"
    /// for a nearly-full device, which rounding both the same direction
    /// avoids.
    private func gbRoundedUpText(_ bytes: Int64) -> String {
        let gb = (Double(bytes) / 1_000_000_000).rounded(.up)
        return String(format: "%.0f GB", gb)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(gbRoundedUpText(breakdown.used)) of \(gbRoundedUpText(breakdown.totalCapacity)) Used")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    segment(color: Color(.systemGray3), fraction: fraction(breakdown.otherUsed), totalWidth: geometry.size.width)
                    segment(color: .accentColor, fraction: fraction(breakdown.appUsed), totalWidth: geometry.size.width)
                    segment(color: Color(.systemGray5), fraction: fraction(breakdown.free), totalWidth: geometry.size.width)
                }
            }
            .frame(height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack(spacing: 20) {
                legendItem(
                    color: Color(.systemGray3), label: String(localized: "Other"), value: nil,
                    accessibilityLabel: String(localized: "Other: \(spokenFileSize(breakdown.otherUsed))")
                )
                legendItem(
                    color: .accentColor, label: String(localized: "This App"), value: appUsedText,
                    accessibilityLabel: String(localized: "This App: \(spokenFileSize(breakdown.appUsed))")
                )
                legendItem(
                    color: Color(.systemGray5), label: String(localized: "Free"), value: nil,
                    // "Free space", not the bare "Free" the visual label
                    // uses — "Free: 50 gigabytes" on its own reads
                    // ambiguously out of context, per direct feedback.
                    accessibilityLabel: String(localized: "Free space: \(spokenFileSize(breakdown.free))")
                )
            }
            .font(.caption)

            if let freeSpaceEstimateText {
                Text(freeSpaceEstimateText)
                    .font(.footnote)
                    .padding(.top, 4)
            }
        }
    }

    private func fraction(_ value: Int64) -> Double {
        guard breakdown.totalCapacity > 0 else { return 0 }
        return Double(value) / Double(breakdown.totalCapacity)
    }

    private func segment(color: Color, fraction: Double, totalWidth: Double) -> some View {
        color.frame(width: max(0, totalWidth * fraction))
    }

    private func legendItem(color: Color, label: String, value: String?, accessibilityLabel: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            if let value {
                Text("\(label) (\(value))")
            } else {
                Text(label)
            }
        }
        .foregroundStyle(.secondary)
        // Other/Free show no visual value at all today (`value: nil` —
        // only "This App" has one, in the parenthetical), so without this
        // VoiceOver read just the bare "Other"/"Free" with no size at all;
        // "This App" already had a value but it was still the same raw
        // "GB"-reads-as-letters problem every other size in this app had.
        // One explicit grouped label fixes both at once, for all three.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// See `DownloadedInfoMetadataRow.spokenFileSize(_:)` — identical parse-
    /// and-replace idea, adapted to work from raw bytes directly (this view
    /// already owns `byteFormatter`, so there's a formatted string to
    /// parse without a caller needing to produce one first).
    private func spokenFileSize(_ bytes: Int64) -> String {
        let text = Self.byteFormatter.string(fromByteCount: bytes)
        guard let spaceIndex = text.lastIndex(of: " ") else { return text }
        let number = text[..<spaceIndex]
        let unit = text[text.index(after: spaceIndex)...]
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
        guard let spokenUnit else { return text }
        return "\(number) \(spokenUnit)"
    }
}

#Preview {
    DeviceStorageBarView(
        breakdown: DeviceStorageBreakdown(
            totalCapacity: 128_000_000_000,
            appUsed: 18_000_000_000,
            otherUsed: 74_000_000_000,
            free: 36_000_000_000
        ),
        freeSpaceEstimateText: "Free space for about 12 movies or 50 TV episodes at the current download settings."
    )
    .padding()
}
