import SwiftUI

/// Detail page for one offline-downloaded item — renders entirely from the
/// `DownloadedItemMetadata`/artwork snapshot captured at download time
/// (poster/backdrop/logo from `DownloadFileStore`, everything else from
/// `DownloadedItem`/`.metadata`), not `AssetDetailViewModel`/`MediaItem`
/// (which assume a live, network-backed `BaseItemDto` and make their own
/// network calls for similar items/collections — deliberately not offered
/// here, since those only make sense against a live, browsable library).
/// Its Play button starts the offline `PlayerViewModel` path; its
/// destructive "Delete Download" toolbar button mirrors `ProfileView`'s
/// Sign Out/Change Server `confirmationDialog` pattern.
struct DownloadedAssetDetailView: View {
    let itemID: String
    let downloadManager: DownloadManager

    @Environment(\.dismiss) private var dismiss
    @State private var isPlayerPresented = false
    @State private var showDeleteConfirmation = false

    private var downloadedItem: DownloadedItem? { downloadManager.store.item(itemID: itemID) }

    var body: some View {
        Group {
            if let item = downloadedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Backdrop, else Thumb (an episode's own still —
                        // usually present even when it has no Backdrop of
                        // its own or a parent to borrow one from), else
                        // Primary/poster as the last resort.
                        LocalFileImage(url: (item.backdropImagePath ?? item.thumbImagePath ?? item.posterImagePath).map(DownloadFileStore.url(forRelativePath:)))
                            .frame(height: 220)
                            .clipped()

                        VStack(alignment: .leading, spacing: 12) {
                            // The show name — shown unconditionally for
                            // episode content, not just implied by
                            // context, since this page (unlike a live
                            // Show-content page) has no persistent hero
                            // logo/title elsewhere on screen naming it.
                            if let seriesTitle = item.seriesTitle {
                                Text(seriesTitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text(item.title).font(.title2.bold())
                            if let episodeLabel = item.episodeLabel {
                                Text(episodeLabel).foregroundStyle(.secondary)
                            }

                            metadataLine(item)

                            if item.status == .completed {
                                Button {
                                    isPlayerPresented = true
                                } label: {
                                    Label(playButtonTitle(item), systemImage: "play.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.dionysusPrimary)
                                .controlSize(.large)
                            } else {
                                downloadStatusRow(item)
                            }

                            if let overview = item.metadata.overview, !overview.isEmpty {
                                Text(overview)
                            }

                            if !item.metadata.genres.isEmpty {
                                Text(item.metadata.genres.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if !item.skippedSubtitleTracks.isEmpty {
                                Text("Not available offline (image-based subtitles): \(item.skippedSubtitleTracks.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if !item.metadata.people.isEmpty {
                                castSection(item)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 32)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { showDeleteConfirmation = true } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                .confirmationDialog(
                    "Delete this download?", isPresented: $showDeleteConfirmation, titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        downloadManager.delete(itemID: item.itemID)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .fullScreenCover(isPresented: $isPlayerPresented) {
                    PlayerView(itemID: item.itemID, downloadedItem: item)
                }
            } else {
                ErrorStateView(message: String(localized: "This download is no longer available."), retry: nil)
            }
        }
    }

    /// Stands in for the Play button while the download isn't actually
    /// playable yet — Play is deliberately not just disabled-but-visible:
    /// the file on disk may not exist yet at all (`.queued`) or be only
    /// partially written (`.downloading`), so starting playback would fail
    /// or play garbage rather than just being briefly unavailable.
    @ViewBuilder
    private func downloadStatusRow(_ item: DownloadedItem) -> some View {
        HStack(spacing: 12) {
            switch item.status {
            case .downloading, .queued:
                if let progress = downloadManager.activeDownloads[item.itemID] {
                    DownloadProgressRing(progress: progress)
                        .frame(width: 32, height: 32)
                    Text(progress.statusText)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Preparing download…")
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(item.errorMessage ?? String(localized: "Download failed."))
            case .paused:
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("Download Paused")
            case .completed:
                EmptyView()
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playButtonTitle(_ item: DownloadedItem) -> String {
        if item.isPlayed { return String(localized: "Play Again") }
        if item.resumePositionTicks > 0 { return String(localized: "Resume") }
        return String(localized: "Play")
    }

    /// Age rating, runtime, resolution, HDR (when applicable), whether
    /// subtitles are included, and the actual on-disk file size — what
    /// actually varies per download and is useful to know offline.
    /// Deliberately omits video codec: every download is transcoded to
    /// HEVC (see the offline-downloads plan), so showing it would just be
    /// the same word on every single item, unlike `MediaItem
    /// .metadataBadges`'s live equivalent, which shows codec-derived audio
    /// format badges that genuinely do vary.
    private func metadataLine(_ item: DownloadedItem) -> some View {
        HStack(spacing: 6) {
            if let rating = item.metadata.officialRating {
                Text(rating)
            }
            if let duration = Self.durationText(ticks: item.runtimeTicks) {
                Text(duration)
            }
            if let resolution = Self.resolutionLabel(height: item.height) {
                Text(resolution)
            }
            if item.isHDR { Text("HDR") }
            if !item.subtitleFiles.isEmpty { Text("CC") }
            if let fileSize = DownloadFileStore.fileSize(forRelativePath: item.videoFilePath) {
                Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    /// Same "Xh Ym" formatting as `MediaItem.durationText` — duplicated
    /// rather than shared since that one is `private` on a type built
    /// around a live `BaseItemDto`, and this only needs the one line of
    /// tick math.
    private static func durationText(ticks: Int64?) -> String? {
        guard let ticks, ticks > 0 else { return nil }
        let totalMinutes = Int(ticks / 10_000_000 / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Coarse SD/HD/4K buckets — matches this page's original, simpler
    /// vocabulary rather than `MediaItem.metadataBadges`' own "4K"/"HD"-
    /// only distinction stretched to a finer 1440p/1080p/720p/480p split;
    /// reverted per direct feedback that the finer buckets read as less
    /// user-friendly here.
    private static func resolutionLabel(height: Int?) -> String? {
        guard let height else { return nil }
        if height >= 2160 { return "4K" }
        if height >= 720 { return "HD" }
        return "SD"
    }

    private func castSection(_ item: DownloadedItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cast & Crew").font(.headline)
            ForEach(Array(item.metadata.people.enumerated()), id: \.offset) { pair in
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(pair.element.name)
                        if let role = pair.element.role {
                            Text(role).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
