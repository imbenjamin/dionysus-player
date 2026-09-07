import SwiftUI

/// The `.regular`-size-class (iPad, and iPhone Pro Max/Plus/Air in
/// landscape) presentation shared by every Downloads screen —
/// `DownloadsView`, `DownloadedShowView`, and `DownloadedSeasonView` all
/// swap their full-width `List` for this above `.compact`.
///
/// Exists for the same reason `SearchView.resultsGrid`/`historyGrid` do, and
/// reuses the same `PosterGridMetrics` column-fitting `CollectionGridView`
/// established: a single-column `List` reads fine on iPhone but left ~72% of
/// an iPad portrait screen empty (measured during the iPad HIG review,
/// 2026-09-03), with each 780pt-wide row holding ~250pt of content and
/// throwing its trailing accessory (chevron/progress ring/retry button) some
/// 600pt away from the title it belongs to — 1000pt in landscape. Same
/// "unmodified iPhone layout" issue Home's rails and Search's results both
/// already had.
///
/// `idealItemWidth` matches `SearchView.grid`'s own 160/260 split rather
/// than `PosterGridMetrics`'s iPhone-oriented 130 default, so Downloads
/// tiles land at the same deliberately-bigger-on-iPad sizing every other
/// `.regular` grid in the app uses.
struct DownloadsGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    /// The whole grid's one shape decision, not any single item's — see
    /// `DownloadedItem.isLandscapeShaped` and `MediaCollectionRail
    /// .usesLandscapeTiles` for why a mixed-shape grid reads worse than a
    /// consistent one.
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

/// One tile in a `DownloadsGrid` — the `.regular` counterpart to
/// `DownloadsView`'s `DownloadsRowView` and `DownloadedEpisodeRow`, and a
/// close sibling of `SearchResultGridCard` (artwork, title, subtitle, and an
/// optional corner button over the image).
///
/// Takes already-resolved display strings rather than a `DownloadsRow` or
/// `DownloadedItem`, for two reasons: it's shared by three screens whose
/// row models differ, and — more importantly — it must never hold a live
/// SwiftData model reference, exactly as `DownloadedEpisodeSummary`'s doc
/// comment explains for the list rows. A grid tile animating out after a
/// delete would trap on the same deleted-model property access.
struct DownloadsGridCard: View {
    let title: String
    let subtitle: String?
    /// Relative to `DownloadFileStore`'s root — resolved to a local file URL
    /// here. Local artwork only; never routed through `RemoteImageLoader`,
    /// see `LocalFileImage`'s own doc comment.
    let artworkRelativePath: String?
    let placeholderSystemImage: String
    let width: CGFloat
    let isLandscape: Bool
    /// Composed by the caller so VoiceOver reads the same "name, subtitle,
    /// status" sentence the equivalent list row would — house pattern is
    /// `.accessibilityElement(children: .ignore)` plus an explicit label,
    /// same as `PosterCard`/`LandscapeMediaCard`/`SearchResultGridCard`.
    let accessibilityLabel: String

    var isSelecting: Bool = false
    var isSelected: Bool = false
    /// Live byte progress while downloading; `nil` once complete, failed, or
    /// still in its "preparing" window (see `isPreparing`).
    var progress: DownloadProgress? = nil
    /// Queued/downloading but with no byte progress to show yet — a plain
    /// spinner beats blank space, same call `DownloadButton.isPreparing`
    /// makes.
    var isPreparing: Bool = false
    /// Shown under the subtitle in place of nothing — "Queued…", a failure
    /// message, etc. `isStatusError` tints it red.
    var statusText: String? = nil
    var isStatusError: Bool = false
    /// On-disk size, already formatted. Unlike the `.compact` list rows
    /// (which only surface this in selection mode, where there's room), a
    /// tile always has room for it — and storage management is the main
    /// reason to open this screen at all.
    var sizeText: String? = nil
    /// What tapping the tile pushes when not selecting. A `NavigationLink`
    /// value rather than an imperative callback, matching every Downloads
    /// list row (`DownloadsRowView`/`DownloadedEpisodeRow`) and avoiding
    /// threading a `NavigationPath` binding down from `MainTabView`, which
    /// doesn't keep one for this tab.
    var navigationValue: AppRoute? = nil
    var onToggleSelection: () -> Void = {}
    /// `nil` hides the retry button entirely rather than showing it
    /// disabled — same rule as `DownloadsView.retryAction(_:)`.
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

    /// Bottom-trailing, matching the app-wide thumbnail overlay scheme
    /// (favorite top-left, watched top-right, logo bottom-left, download
    /// bottom-right) this project settled on — a download's own progress
    /// belongs in the same corner its download button would.
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

    /// Top-left, the same corner the app-wide scheme gives the favorite
    /// badge — selection is a per-tile state marker, not an action, so it
    /// reads as a badge rather than a button. The tile as a whole is what
    /// toggles it (`isSelecting` swaps the button's action above), so this
    /// needs no tap target of its own.
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

    /// Same "visible circle smaller than its tap target" idiom
    /// `SearchResultGridCard`'s remove button uses — a 28pt glyph grown to a
    /// 44x44pt target, HIG's default mobile control size, rather than the
    /// bare glyph bounds.
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
