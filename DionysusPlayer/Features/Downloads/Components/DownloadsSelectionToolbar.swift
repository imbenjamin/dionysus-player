import SwiftUI

/// The bulk-delete toolbar shared by `DownloadsView`, `DownloadedShowView` and
/// `DownloadedSeasonView`, in the Photos/Files shape: "Select" enters selection
/// mode; inside it, Cancel top-left, then Select All and a destructive trash
/// top-right.
///
/// Entering selection used to be a trash icon too, so the one control that
/// deleted nothing looked the most destructive, and the same glyph meant two
/// things depending on mode. Trash now only ever deletes.
///
/// Everything sits in the top nav bar, not `.bottomBar`: iOS 26's floating tab
/// bar sits above `.bottomBar` and covers it. The count goes in each screen's
/// confirmation dialog rather than on the trash button, keeping it icon-only
/// so it fits beside Cancel and Select All.
///
/// The identifiers are the same on all three screens; only one is ever on
/// screen at a time.
struct DownloadsSelectionToolbar: ToolbarContent {
    let isSelecting: Bool
    let isAllSelected: Bool
    let hasSelection: Bool
    let onBeginSelecting: () -> Void
    let onCancel: () -> Void
    let onToggleSelectAll: () -> Void
    let onDelete: () -> Void

    var body: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .neutralToolbarItem()
                    .accessibilityIdentifier(A11yID.Downloads.cancelSelectionButton)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isAllSelected ? "Deselect All" : "Select All", action: onToggleSelectAll)
                    .neutralToolbarItem()
                    .accessibilityIdentifier(A11yID.Downloads.selectAllButton)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").downloadsToolbarTapTarget()
                }
                .destructiveToolbarItem()
                .disabled(!hasSelection)
                .accessibilityLabel(String(localized: "Delete Selected Downloads"))
                .accessibilityIdentifier(A11yID.Downloads.deleteSelectedButton)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select", action: onBeginSelecting)
                    .neutralToolbarItem()
                    .accessibilityIdentifier(A11yID.Downloads.selectButton)
            }
        }
    }
}
