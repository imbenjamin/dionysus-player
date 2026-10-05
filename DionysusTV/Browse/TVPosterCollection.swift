import SwiftUI
import TVUIKit
import UIKit

/// The grid's posters in a UIKit collection view, for the one thing SwiftUI
/// has no way to ask for on tvOS: the system's alphabet index, the column
/// that appears at the right edge while scrolling fast
/// (`indexTitles(for:)`; SwiftUI's `sectionIndexLabel` is for `List` only).
///
/// Each cell is the system's own poster (`TVPosterView`): artwork that
/// lifts on focus, the title and subtitle beneath, and the app's badges over
/// the artwork. It was the app's SwiftUI tile at first, hosted in the cell,
/// but focus inside a hosted SwiftUI view is invisible to UIKit: Up from the
/// top row went nowhere, and releasing the index after scrubbing left
/// nothing focused, with every button dead (Benjamin, 2026-10-03). With a
/// UIKit view taking focus, the collection view, the index and the page's
/// SwiftUI header all move it the ordinary way.
///
/// What `tvClaimsFocus` does for a SwiftUI page is done here by hand: the
/// first tile on arrival and on each handoff from the sidebar, the
/// remembered one when the page comes back on show, and whatever has focus
/// written to `rememberedItemID`.
struct TVPosterCollection: UIViewRepresentable {
    let items: [MediaItem]
    /// Posters or landscape thumbs (`TVTileShape`), for the whole grid.
    let shape: TVTileShape
    /// Whether the alphabet index is offered: only while sorted by title.
    let showsIndex: Bool
    /// Room at the top for the page's header, which is drawn over the
    /// collection view and moved with its scrolling (`onScroll`).
    let topInset: CGFloat
    /// True while a pill's list is open: focus stays out of the grid.
    let isLocked: Bool
    /// Bumped to send the grid back to its top.
    let scrollToTopToken: Int
    @Binding var rememberedItemID: String?
    /// How far the content has scrolled from its top, zero or more.
    let onScroll: (CGFloat) -> Void
    /// Asks SwiftUI to put focus back on the page's default, which is this
    /// grid (`prefersDefaultFocus`). UIKit refuses a focus update requested
    /// of a cell while SwiftUI holds focus in the header (measured: every
    /// request left focus on the first pill), but SwiftUI's own reset is
    /// honoured, and lands on `preferredFocusEnvironments`.
    let resetFocus: () -> Void
    let open: (MediaItem) -> Void

    @Environment(\.tvPageIsOnShow) private var isOnShow
    @Environment(\.tvFocusHandoff) private var handoff
    @Environment(\.tvSidebarExpanded) private var sidebarExpanded
    @Environment(\.tvPageClaimedFocus) private var claimed
    @Environment(\.isEnabled) private var isEnabled

    static let columnSpacing: CGFloat = 44
    static let rowSpacing: CGFloat = 60

    /// A tile and its two-line caption.
    static func cellSize(_ shape: TVTileShape) -> CGSize {
        CGSize(width: shape.gridSize.width, height: shape.gridSize.height + 90)
    }

    /// Six posters or four thumbs to a row, the same width either way.
    static func layout(_ shape: TVTileShape) -> UICollectionViewCompositionalLayout {
        let cell = cellSize(shape)
        let columns = CGFloat(shape.gridColumns)
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(cell.width), heightDimension: .absolute(cell.height)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(columns * cell.width + (columns - 1) * columnSpacing), heightDimension: .absolute(cell.height)),
            subitems: [item]
        )
        group.interItemSpacing = .fixed(columnSpacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = rowSpacing
        return UICollectionViewCompositionalLayout(section: section)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let view = TVPosterCollectionView(frame: .zero, collectionViewLayout: Self.layout(shape))
        view.backgroundColor = .clear
        // A focused tile lifts past the collection view's edges.
        view.clipsToBounds = false
        view.contentInsetAdjustmentBehavior = .never
        view.remembersLastFocusedIndexPath = false
        view.register(TVPosterCell.self, forCellWithReuseIdentifier: Coordinator.reuseID)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        context.coordinator.collectionView = view
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(to: self, in: view)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        static let reuseID = "tile"
        private var parent: TVPosterCollection
        weak var collectionView: UICollectionView?
        /// True while focus is being put on a tile, when nothing is
        /// remembered.
        private var isPlacingFocus = false
        private var hasClaimed = false
        private var restoreTask: Task<Void, Never>?

        init(_ parent: TVPosterCollection) { self.parent = parent }

        // MARK: Updates from SwiftUI

        func update(to new: TVPosterCollection, in view: UICollectionView) {
            let old = parent
            parent = new
            view.isUserInteractionEnabled = new.isEnabled && !new.isLocked

            if view.contentInset.top != new.topInset || view.contentInset.bottom != 160 {
                let atTop = view.contentOffset.y <= -view.contentInset.top + 1
                view.contentInset = UIEdgeInsets(top: new.topInset, left: 0, bottom: 160, right: 0)
                if atTop { view.contentOffset.y = -new.topInset }
            }

            if old.shape != new.shape {
                view.setCollectionViewLayout(TVPosterCollection.layout(new.shape), animated: false)
            }
            if old.items.map(\.id) != new.items.map(\.id) || old.showsIndex != new.showsIndex || old.shape != new.shape {
                // Done now, not left for UIKit's next pass: deferred, the
                // reload ran inside a focus update (asked whether a cell
                // could take focus), reused the cell that had focus, and
                // UIKit's focus system aborted the app (seen opening See All
                // from Home and coming back).
                view.reloadData()
                view.layoutIfNeeded()
                // A new list (a filter, a sort) starts at its top.
                if hasClaimed, old.items.map(\.id) != new.items.map(\.id) {
                    view.setContentOffset(CGPoint(x: 0, y: -new.topInset), animated: false)
                }
            } else if old.items != new.items {
                // The same titles with something changed (a badge): redraw
                // what's on screen where it is.
                for indexPath in view.indexPathsForVisibleItems {
                    if let cell = view.cellForItem(at: indexPath) { configure(cell, at: indexPath) }
                }
            }

            if old.scrollToTopToken != new.scrollToTopToken {
                view.setContentOffset(CGPoint(x: 0, y: -new.topInset), animated: true)
            }

            guard new.isOnShow, !new.items.isEmpty else {
                if !new.isOnShow { restoreTask?.cancel() }
                return
            }
            if !hasClaimed {
                // Arrival: the remembered tile if it's still listed (the page
                // rebuilt after being torn down), otherwise the first.
                hasClaimed = true
                guard !new.sidebarExpanded else { return }
                focus(itemID: new.rememberedItemID, in: view)
            } else if old.handoff != new.handoff {
                // Chosen from the sidebar: a page opens at its start.
                focus(itemID: nil, in: view)
            } else if !old.isOnShow {
                // Back on show after the page above was popped.
                focus(itemID: new.rememberedItemID, in: view)
            }
        }

        /// Puts focus on a tile, the first when `itemID` is `nil` or no
        /// longer listed. The cell has to be on screen to take focus, and a
        /// request made while the page is still being enabled is dropped, so
        /// it is made until it holds.
        private func focus(itemID: String?, in view: UICollectionView) {
            let index = itemID.flatMap { id in parent.items.firstIndex { $0.id == id } } ?? 0
            let target = IndexPath(item: index, section: 0)
            let id = parent.items[index].id
            isPlacingFocus = true
            restoreTask?.cancel()
            restoreTask = Task { @MainActor [weak self, weak view] in
                // Up to a second and a half: the shell asks the focus system
                // to update once it has handed the page focus, and that can
                // come after the first requests, taking focus to the
                // header's first pill.
                var held = 0
                for _ in 0..<30 {
                    guard let self, let view, !Task.isCancelled else { return }
                    view.layoutIfNeeded()
                    if view.cellForItem(at: target) == nil {
                        view.scrollToItem(at: target, at: .centeredVertically, animated: false)
                        view.layoutIfNeeded()
                    }
                    (view as? TVPosterCollectionView)?.focusTarget = target
                    self.parent.resetFocus()
                    // And from the window's root, as the shell hands a page
                    // focus: on its own the reset sometimes left focus where
                    // it was (one opening in four, measured), on the rail.
                    if let root = view.window?.rootViewController, let system = UIFocusSystem.focusSystem(for: view) {
                        system.requestFocusUpdate(to: root)
                        system.updateFocusIfNeeded()
                    }
                    // Held for a few passes in a row, so a later request
                    // from the shell can't take it straight back.
                        let ok = self.focusedIndexPath(in: view) == target
                held = ok ? held + 1 : 0
                    if held >= 4 { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard let self else { return }
                (self.collectionView as? TVPosterCollectionView)?.focusTarget = nil
                self.isPlacingFocus = false
                if self.parent.rememberedItemID != id { self.parent.rememberedItemID = id }
                self.parent.claimed()
            }
        }

        /// The cell holding whatever has focus.
        private func focusedIndexPath(in view: UICollectionView) -> IndexPath? {
            var current: UIFocusEnvironment? = UIFocusSystem.focusSystem(for: view)?.focusedItem
            while let environment = current {
                if let cell = environment as? UICollectionViewCell { return view.indexPath(for: cell) }
                current = environment.parentFocusEnvironment
            }
            return nil
        }

        // MARK: Data source

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { parent.items.count }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseID, for: indexPath)
            configure(cell, at: indexPath)
            return cell
        }

        private func configure(_ cell: UICollectionViewCell, at indexPath: IndexPath) {
            guard let cell = cell as? TVPosterCell, parent.items.indices.contains(indexPath.item) else { return }
            let item = parent.items[indexPath.item]
            let open = parent.open
            cell.show(item, shape: parent.shape) { open(item) }
        }

        func indexTitles(for collectionView: UICollectionView) -> [String]? {
            guard parent.showsIndex else { return nil }
            return TVAlphabetIndex.indexTitles(parent.items.map(\.name))
        }

        func collectionView(_ collectionView: UICollectionView, indexPathForIndexTitle title: String, at index: Int) -> IndexPath {
            IndexPath(item: TVAlphabetIndex.firstIndex(under: title, in: parent.items.map(\.name)) ?? 0, section: 0)
        }

        // MARK: Focus

        /// The poster inside takes focus, not the cell around it.
        func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { false }

        func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            // A hidden page remembers nothing, and neither does one whose
            // focus is still being put back.
            guard parent.isOnShow, !isPlacingFocus,
                  let indexPath = focusedIndexPath(in: collectionView), parent.items.indices.contains(indexPath.item) else { return }
            let id = parent.items[indexPath.item].id
            if parent.rememberedItemID != id { parent.rememberedItemID = id }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll(max(0, scrollView.contentOffset.y + scrollView.contentInset.top))
        }
    }
}

/// Focus asked of the collection view goes to `focusTarget`'s cell, and
/// from there to its poster.
final class TVPosterCollectionView: UICollectionView {
    var focusTarget: IndexPath?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let focusTarget, let cell = cellForItem(at: focusTarget) { return [cell] }
        return super.preferredFocusEnvironments
    }
}

/// A grid cell: the system poster, with the app's badges over its artwork
/// and the artwork loaded through `RemoteImageLoader` like every other image.
final class TVPosterCell: UICollectionViewCell {
    private let poster = TVCaptionedPosterView(frame: .zero)
    private let badges = UIHostingController(rootView: TVPosterOverlay(item: nil, isLoaded: false))
    private var itemID: String?
    private var shape: TVTileShape = .poster
    private lazy var posterWidth = poster.widthAnchor.constraint(equalToConstant: TVTileMetrics.gridPoster.width)
    private var imageTask: Task<Void, Never>?
    private var action: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        poster.translatesAutoresizingMaskIntoConstraints = false
        poster.contentSize = TVTileMetrics.gridPoster
        poster.imageView.adjustsImageWhenAncestorFocused = true
        poster.imageView.contentMode = .scaleAspectFill
        poster.addTarget(self, action: #selector(openTile), for: .primaryActionTriggered)
        contentView.addSubview(poster)
        NSLayoutConstraint.activate([
            poster.topAnchor.constraint(equalTo: contentView.topAnchor),
            poster.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            posterWidth
        ])
        // Over the artwork, so the badges lift with it.
        let overlay = poster.imageView.overlayContentView
        badges.view.backgroundColor = .clear
        badges.view.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(badges.view)
        NSLayoutConstraint.activate([
            badges.view.topAnchor.constraint(equalTo: overlay.topAnchor),
            badges.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            badges.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            badges.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [poster] }

    /// The poster takes focus, never the cell, so the cell says so itself.
    /// Left to UIKit the answer comes from the collection view, which can
    /// reload its data to find the cell's index path; asked while the grid
    /// was being removed with a poster focused (popping a See All grid), that
    /// reload reused the focused cell and UIKit's focus system aborted the
    /// app.
    override var canBecomeFocused: Bool { false }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        poster.image = nil
    }

    func show(_ item: MediaItem, shape: TVTileShape, action: @escaping () -> Void) {
        self.action = action
        let isNewItem = itemID != item.id || self.shape != shape
        itemID = item.id
        if self.shape != shape {
            self.shape = shape
            posterWidth.constant = shape.gridSize.width
            poster.contentSize = shape.gridSize
        }
        poster.title = item.railTitle
        poster.subtitle = item.railSubtitle
        poster.styleCaption()
        poster.accessibilityIdentifier = A11yID.TV.Library.tile(item.id)
        poster.accessibilityLabel = item.accessibilityDescription
        poster.accessibilityValue = TVTileBadges.spokenValue(for: item)
        poster.accessibilityTraits = .button

        guard isNewItem || poster.image == nil else {
            badges.rootView = TVPosterOverlay(item: item, isLoaded: true)
            return
        }
        imageTask?.cancel()
        // A thumb for a landscape grid, as `TVLandscapeTile` draws it.
        let artwork = shape == .landscape ? (item.thumbImageURL ?? item.primaryImageURL) : item.primaryImageURL
        guard let url = artwork else {
            poster.image = nil
            badges.rootView = TVPosterOverlay(item: item, isLoaded: false, isSettled: true)
            return
        }
        if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            // Set a pass later, as a fetched image is: set while the cell
            // is still being configured, before it's on screen, the poster
            // kept its artwork at full size (every revisit, measured).
            imageTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled, self.itemID == item.id else { return }
                self.setImage(cached)
            }
            badges.rootView = TVPosterOverlay(item: item, isLoaded: true)
            return
        }
        poster.image = nil
        badges.rootView = TVPosterOverlay(item: item, isLoaded: false)
        imageTask = Task { @MainActor [weak self] in
            let image = try? await RemoteImageLoader.shared.image(for: url)
            guard let self, !Task.isCancelled, self.itemID == item.id else { return }
            self.setImage(image)
            self.badges.rootView = TVPosterOverlay(item: item, isLoaded: image != nil, isSettled: image == nil)
        }
    }

    /// The poster insets its artwork so the lift on focus fits inside its
    /// frame, working the inset out from the image and `contentSize`. Given
    /// an image without a fresh layout (a cached one, set before the cell was
    /// on screen) it sometimes kept the artwork at full size, so the lift ran
    /// over the caption, which stayed put: about half the times a grid opened
    /// (Benjamin, 2026-10-03). The size is set again with every image.
    private func setImage(_ image: UIImage?) {
        poster.image = image
        poster.contentSize = shape.gridSize
        poster.setNeedsLayout()
    }

    @objc private func openTile() { action() }
}

/// The system poster with its title and subtitle styled as the app's own
/// tile captions (`TVPosterTile`): left-aligned, the title in semibold
/// caption, the subtitle smaller and secondary, one line each (Benjamin,
/// 2026-10-03). Still the system's labels in the system's footer, so they
/// keep its focus behaviour; the style is put back after every appearance
/// change, since the footer restyles its labels as focus comes and goes.
final class TVCaptionedPosterView: TVPosterView {
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        styleCaption()
        coordinator.addCoordinatedAnimations { self.styleCaption() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        styleCaption()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        footerView = TVLeadingCaptionFooter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func styleCaption() {
        guard let footer = footerView else { return }
        if let title = footer.titleLabel {
            let font = UIFont.preferredFont(forTextStyle: .caption1)
            title.font = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            title.textColor = .white
            title.textAlignment = .natural
            title.numberOfLines = 1
            title.lineBreakMode = .byTruncatingTail
        }
        if let subtitle = footer.subtitleLabel {
            subtitle.font = UIFont.preferredFont(forTextStyle: .caption2)
            subtitle.textColor = UIColor.white.withAlphaComponent(0.6)
            subtitle.textAlignment = .natural
            subtitle.numberOfLines = 1
            subtitle.lineBreakMode = .byTruncatingTail
        }
    }
}

/// The poster's footer with its labels laid along its leading edge across
/// its full width; the system centres each label on its own text.
final class TVLeadingCaptionFooter: TVLockupHeaderFooterView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for label in [titleLabel, subtitleLabel].compactMap({ $0 }) {
            label.frame = CGRect(x: 0, y: label.frame.minY, width: bounds.width, height: label.frame.height)
        }
    }
}

/// What's drawn over a poster's artwork: the placeholder glyph while it
/// loads, then the badges.
struct TVPosterOverlay: View {
    let item: MediaItem?
    let isLoaded: Bool
    var isSettled = false

    var body: some View {
        ZStack {
            if let item {
                if !isLoaded {
                    MediaPlaceholderBox(systemImage: item.kind.placeholderSystemImage, isSettled: isSettled)
                }
                TVTileBadges(badges: WatchBadges(item: item))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}
