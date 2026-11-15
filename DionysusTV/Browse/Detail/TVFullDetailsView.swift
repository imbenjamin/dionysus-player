import SwiftUI

/// Everything the Details panel summarises, in full (Benjamin, 2026-10-02):
/// what iOS's Details tab lists (container, codec, resolution, frame rate,
/// dynamic range, bitrate, file size) and every audio and subtitle track.
/// Laid over the detail page; Menu closes it.
///
/// A title with several versions (#289) shows one at a time, chosen by a row
/// of tabs under the title, as iOS's Details tab does with its picker: listed
/// one after another, two 4K and 1080p files read as one long run of
/// near-identical rows.
///
/// Each section is focusable, since a tvOS scroll view moves only with focus.
struct TVFullDetailsView: View {
    let item: MediaItem
    @State private var versionID: String?
    @FocusState private var focused: String?
    /// For the unselected version tabs' translucency, which Increase Contrast
    /// doesn't brighten by itself (`TVContrast`).
    @Environment(\.colorSchemeContrast) private var contrast

    /// `initialVersionID` is the version the page's panel summarised (the
    /// remembered pick), so the full list opens on what the panel showed.
    init(item: MediaItem, initialVersionID: String? = nil) {
        self.item = item
        _versionID = State(initialValue: Self.selectedVersionID(in: item, preferred: initialVersionID))
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        var rows: [(label: String, value: String, spoken: String?)] = []
        var lines: [String] = []
    }

    /// The version whose tab is selected: the preferred one when the title
    /// still has it, else the first (the one the server would play). `nil`
    /// for a title with one version or none, which has no tabs.
    static func selectedVersionID(in item: MediaItem, preferred: String?) -> String? {
        let versions = item.mediaVersions
        guard versions.count > 1 else { return nil }
        return versions.first { $0.id == preferred }?.id ?? versions.first?.id
    }

    /// About, then the chosen version's Video, Audio and Subtitles. The
    /// version needs no name in the headings: its tab is marked above them.
    /// A section's id carries the version ("video.<id>"), or "default" for a
    /// single-version title, so a switch replaces the sections.
    static func sections(for item: MediaItem, versionID: String?) -> [Section] {
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

        let selected = selectedVersionID(in: item, preferred: versionID)
        guard let details = item.technicalDetails(forVersion: selected), !details.isEmpty else { return result }
        let key = selected ?? "default"
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
            result.append(Section(id: "video.\(key)", title: String(localized: "Video"), rows: videoRows))
        }
        if !details.audioTracks.isEmpty {
            result.append(Section(id: "audio.\(key)", title: String(localized: "Audio"), lines: details.audioTracks))
        }
        if !details.subtitleTracks.isEmpty {
            result.append(Section(id: "subtitles.\(key)", title: String(localized: "Subtitles"), lines: details.subtitleTracks))
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

    private static func tabFocusID(_ versionID: String) -> String { "version.\(versionID)" }

    var body: some View {
        let sections = Self.sections(for: item, versionID: versionID)
        let versions = item.mediaVersions
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(verbatim: item.name)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(A11yID.TV.Detail.fullDetailsTitle)
                if versions.count > 1 {
                    versionTabs(versions)
                }
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
        // With tabs, focus starts on the version on show, which says there
        // are others; without, on the first section as before.
        .onAppear { focused = versionID.map(Self.tabFocusID) ?? sections.first?.id }
        // The tabs behave as a tvOS tab bar, as a show's season tabs do: the
        // tab with focus is the version on show, no Select needed.
        .onChange(of: focused) { _, newValue in
            guard let newValue, newValue.hasPrefix("version.") else { return }
            let id = String(newValue.dropFirst("version.".count))
            if id != versionID { versionID = id }
        }
    }

    /// One button per version. The selected tab is bold, at full strength and
    /// underlined, so it reads without relying on colour, and carries the
    /// selected trait for VoiceOver. Select does what focus already did, for
    /// VoiceOver, whose cursor can rest on a tab without focusing it.
    private func versionTabs(_ versions: [MediaVersion]) -> some View {
        HStack(spacing: 16) {
            ForEach(versions) { version in
                let isSelected = version.id == versionID
                Button { versionID = version.id } label: {
                    Text(verbatim: version.label)
                        .fontWeight(isSelected ? .bold : .regular)
                        .opacity(isSelected ? 1 : TVContrast.opacity(0.6, increased: contrast == .increased))
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                Capsule().frame(height: 4).offset(y: 10).accessibilityHidden(true)
                            }
                        }
                }
                .focused($focused, equals: Self.tabFocusID(version.id))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier(A11yID.TV.Detail.versionTab(version.id))
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The row spans the width, so Up from any section reaches it; and
        // entering it, focus goes to the version on show, not the nearest tab
        // (which, as a tab, would switch the version on the way past).
        .focusSection()
        .defaultFocus($focused, versionID.map(Self.tabFocusID), priority: .userInitiated)
    }
}
