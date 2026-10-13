import SwiftUI

/// Everything the Details panel summarises, in full (Benjamin, 2026-10-02):
/// what iOS's Details tab lists (container, codec, resolution, frame rate,
/// dynamic range, bitrate, file size) and every audio and subtitle track,
/// for each version of the title. Laid over the detail page; Menu closes it.
///
/// Each section is focusable, since a tvOS scroll view moves only with focus.
struct TVFullDetailsView: View {
    let item: MediaItem
    @FocusState private var focused: String?

    private struct Section: Identifiable {
        let id: String
        let title: String
        var rows: [(label: String, value: String, spoken: String?)] = []
        var lines: [String] = []
    }

    private var sections: [Section] {
        var result: [Section] = []
        let about: [(String, String?)] = [
            (String(localized: "Studio"), item.studios.isEmpty ? nil : item.studios.joined(separator: ", ")),
            (String(localized: "Released"), item.metadataDateText),
            (String(localized: "Genres"), item.genres.isEmpty ? nil : item.genres.joined(separator: ", ")),
            (String(localized: "Rating"), item.ageRating),
            (String(localized: "Runtime"), item.durationText)
        ]
        let runtimeLabel = String(localized: "Runtime")
        let aboutRows = about.compactMap { label, value in
            value.map { (label: label, value: $0, spoken: label == runtimeLabel ? item.durationAccessibilityText : nil) }
        }
        if !aboutRows.isEmpty {
            result.append(Section(id: "about", title: String(localized: "About"), rows: aboutRows))
        }

        // One group per version; a single version needs no name.
        let versions = item.mediaVersions
        let groups: [(id: String?, name: String?)] = versions.count > 1 ? versions.map { ($0.id, $0.label) } : [(nil, nil)]
        for group in groups {
            guard let details = item.technicalDetails(forVersion: group.id), !details.isEmpty else { continue }
            let key = group.id ?? "default"
            let suffix = group.name.map { " · \($0)" } ?? ""
            let video: [(String, String?, String?)] = [
                (String(localized: "Container"), details.container, nil),
                (String(localized: "Video Codec"), details.videoCodec, nil),
                (String(localized: "Resolution"), details.resolution, nil),
                (String(localized: "Frame Rate"), details.frameRate, nil),
                (String(localized: "Dynamic Range"), details.dynamicRange, nil),
                (String(localized: "Bitrate"), details.bitrate, details.bitrateAccessibilityText),
                (String(localized: "File Size"), details.fileSize, details.fileSizeAccessibilityText)
            ]
            let videoRows = video.compactMap { label, value, spoken in value.map { (label: label, value: $0, spoken: spoken) } }
            if !videoRows.isEmpty {
                result.append(Section(id: "video.\(key)", title: String(localized: "Video") + suffix, rows: videoRows))
            }
            if !details.audioTracks.isEmpty {
                result.append(Section(id: "audio.\(key)", title: String(localized: "Audio") + suffix, lines: details.audioTracks))
            }
            if !details.subtitleTracks.isEmpty {
                result.append(Section(id: "subtitles.\(key)", title: String(localized: "Subtitles") + suffix, lines: details.subtitleTracks))
            }
        }
        return result
    }

    /// A section's rows as VoiceOver reads them: "Container, MKV. Video Codec,
    /// HEVC." Tracks are read in full words ("Dolby Digital", not "DD").
    private static func spokenContent(of section: Section) -> String {
        let rows = section.rows.map { "\($0.label), \($0.spoken ?? $0.value)" }
        let lines = section.lines.map(MediaItem.spokenFormats(in:))
        return (rows + lines).joined(separator: ". ")
    }

    var body: some View {
        let sections = sections
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(verbatim: item.name)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(A11yID.TV.Detail.fullDetailsTitle)
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(verbatim: section.title).font(.headline).accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(A11yID.TV.Detail.fullDetailsSectionTitle(section.id))
                        ForEach(section.rows, id: \.label) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 40) {
                                Text(verbatim: row.label).foregroundStyle(.secondary).frame(width: 320, alignment: .leading)
                                Text(verbatim: row.value).accessibilityLabel(row.spoken ?? row.value)
                                Spacer(minLength: 0)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(focused == section.id ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 24))
                    .focusable()
                    .focused($focused, equals: section.id)
                    // One element named for its heading, its rows the value:
                    // as a container VoiceOver said "Audio" and then only the
                    // section's last row (Benjamin, on device, M5).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: section.title))
                    .accessibilityValue(Text(verbatim: Self.spokenContent(of: section)))
                    .accessibilityIdentifier(A11yID.TV.Detail.fullDetailsSection(section.id))
                }
            }
            .padding(.horizontal, 260)
            .padding(.vertical, 80)
        }
        .background { Rectangle().fill(.ultraThickMaterial).ignoresSafeArea() }
        .onAppear { focused = sections.first?.id }
    }
}
