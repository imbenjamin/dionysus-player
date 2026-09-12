import SwiftUI

/// The `.regular`-size-class presentation shared by `DownloadsView`,
/// `DownloadedShowView` and `DownloadedSeasonView`, each swapping its full-width
/// `List` for this above `.compact`.
///
/// Exists for the same reason as `SearchView.resultsGrid`/`historyGrid`, reusing
/// `CollectionGridView`'s `PosterGridMetrics` column fitting: a single-column
/// `List` reads fine on iPhone but left ~72% of an iPad portrait screen empty,
/// each 780pt row holding ~250pt of content and throwing its trailing accessory
/// ~600pt from its title — 1000pt in landscape.
///
/// `idealItemWidth` matches `SearchView.grid`'s 160/260 split rather than
/// `PosterGridMetrics`' iPhone-oriented 130 default, so these tiles match every
/// other `.regular` grid's sizing.
struct DownloadsGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    /// The whole grid's shape decision, not any single item's — see
    /// `DownloadedItem.isLandscapeShaped` and
    /// `MediaCollectionRail.usesLandscapeTiles`.
    let isLandscape: Bool
    @ViewBuilder let card: (Item, CGFloat) -> Card

    var body: some View {
        GeometryReader { proxy in
            let metrics = PosterGridMetrics(
                containerWidth: proxy.size.width, idealItemWidth: isLandscape ? 260 : 160
            )
            ScrollView {
                LazyVGrid(columns: metrics.columns, spacing: 20) {
                    ForEach(items) { item in
                        card(item, metrics.itemWidth)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical)
            }
        }
    }
}

/// One tile in a `DownloadsGrid`: the `.regular` counterpart to
/// `DownloadsRowView`/`DownloadedEpisodeRow`, and a sibling of
/// `SearchResultGridCard` — artwork, title, subtitle and an optional corner
/// button.
///
/// Takes already-resolved display strings rather than a `DownloadsRow` or
/// `DownloadedItem`: it's shared by three screens whose row models differ, and it
/// must never hold a live SwiftData model, as `DownloadedEpisodeSummary`
/// explains — a tile animating out after a delete would trap on the same
/// deleted-model access.
struct DownloadsGridCard: View {
    let title: String
    let subtitle: String?
    /// Relative to `DownloadFileStore`'s root, resolved to a local file URL here.
    /// Local artwork only, never routed through `RemoteImageLoader`; see
    /// `LocalFileImage`.
    let artworkRelativePath: String?
    let placeholderSystemImage: String
    let width: CGFloat
    let isLandscape: Bool
    /// Composed by the caller so VoiceOver reads the same "name, subtitle, status"
    /// sentence the list row would. House pattern is
    /// `.accessibilityElement(children: .ignore)` plus an explicit label, as in
    /// `PosterCard`/`LandscapeMediaCard`/`SearchResultGridCard`.
    let accessibilityLabel: String

    var isSelecting: Bool = false
    var isSelected: Bool = false
    /// Live byte progress while downloading; `nil` once complete, failed, or
    /// still in its "preparing" window (see `isPreparing`).
    var progress: DownloadProgress? = nil
    /// Queued or downloading with no byte progress yet: a spinner beats blank
    /// space, the call `DownloadButton.isPreparing` makes.
    var isPreparing: Bool = false
    /// Shown under the subtitle: "Queued…", a failure message, and so on.
    /// `isStatusError` tints it red.
    var statusText: String? = nil
    var isStatusError: Bool = false
    /// On-disk size, already formatted. A tile always has room for it, unlike the
    /// `.compact` list rows which surface it only in selection mode, and storage
    /// management is the main reason to open this screen.
    var sizeText: String? = nil
    /// What tapping the tile pushes when not selecting. A `NavigationLink` value
    /// rather than an imperative callback, matching the Downloads list rows and
    /// avoiding threading a `NavigationPath` binding down from `MainTabView`, which
    /// doesn't keep one for this tab.
    var navigationValue: AppRoute? = nil
    var onToggleSelection: () -> Void = {}
    /// `nil` hides the retry button rather than disabling it, as in
    /// `DownloadsView.retryAction(_:)`.
    var onRetry: (() -> Void)? = nil
    var isRetrying: Bool = false

    private var imageHeight: CGFloat { isLandscape ? width * 9 / 16 : width * 1.5 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if isSelecting || navigationValue == nil {
                Button(action: onToggleSelection) { tileContent }
                    .buttonStyle(.plain)
            } else if let navigationValue {
                NavigationLink(value: navigationValue) { tileContent }
                    .buttonStyle(.plain)
            }

            if !isSelecting, let onRetry {
                retryButton(action: onRetry)
            }
        }
    }

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork
            textStack
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var artwork: some View {
        LocalFileImage(
            url: artworkRelativePath.map(DownloadFileStore.url(forRelativePath:)),
            targetSize: CGSize(width: width, height: imageHeight),
            placeholderSystemImage: placeholderSystemImage
        )
            .frame(width: width, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) { progressOverlay }
            .overlay(alignment: .topLeading) { selectionOverlay }
    }

    /// Bottom-trailing, per the app-wide thumbnail overlay scheme — favorite
    /// top-left, watched top-right, logo bottom-left, download bottom-right — so
    /// progress sits where a download button would.
    @ViewBuilder
    private var progressOverlay: some View {
        if let progress {
            DownloadProgressRing(progress: progress)
                .frame(width: 28, height: 28)
                .padding(6)
        } else if isPreparing {
            ProgressView()
                .controlSize(.small)
                .padding(6)
        }
    }

    /// Top-left, the corner the app-wide scheme gives the favorite badge:
    /// selection is a state marker, not an action, so it reads as a badge. The
    /// tile as a whole toggles it — `isSelecting` swaps the button's action above
    /// — so this needs no tap target.
    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.dionysusPrimary : Color.white)
                .shadow(radius: 2)
                .padding(6)
        }
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            if let statusText {
                Text(statusText)
                    .font(.caption2)
                    .lineLimit(2)
                    .foregroundStyle(isStatusError ? .red : .secondary)
            }
            if let sizeText {
                Text(sizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// The same visible-circle-smaller-than-tap-target idiom as
    /// `SearchResultGridCard`'s remove button: a 28pt glyph grown to HIG's 44x44pt
    /// minimum rather than the bare glyph bounds.
    private func retryButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isRetrying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 28, height: 28)
            .background(Circle().fill(.black.opacity(0.55)))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRetrying)
        .accessibilityLabel(String(localized: "Retry Download"))
    }
}
