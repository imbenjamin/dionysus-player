import Foundation

/// Three-bucket device storage snapshot backing `DeviceStorageBarView` on
/// `DownloadsSettingsView` — deliberately coarse (This App / Other / Free)
/// rather than the full app-by-app/media-type breakdown iOS Settings'
/// "iPhone Storage" screen shows, per an explicit ask: this app has no way
/// to reproduce that breakdown (no API surfaces per-app or per-media-type
/// usage to a regular app), so it only ever claims to know its own slice.
struct DeviceStorageBreakdown {
    let totalCapacity: Int64
    /// This app's own downloaded-video/image/subtitle footprint —
    /// `DownloadFileStore.totalSizeOnDisk()`, the same figure `ProfileView`
    /// already surfaced as a plain "Storage Used" row before this graph
    /// existed.
    let appUsed: Int64
    /// Derived, not measured: `totalCapacity - free - appUsed`. iOS gives a
    /// regular app no API for "how much every other app/system file is
    /// using" — this is the only way to represent it without over-claiming
    /// precision the app doesn't have.
    let otherUsed: Int64
    let free: Int64

    var used: Int64 { appUsed + otherUsed }

    /// Reads real device capacity off the app's own container volume via
    /// `URLResourceValues`. Returns `nil` if the volume's capacity/available
    /// keys aren't readable (not expected on a real device, but these are
    /// still `Optional` per Apple's own API — `DownloadsSettingsView` falls
    /// back to a plain "Storage Used" figure with no graph in that case,
    /// mirroring what `ProfileView` showed before this existed).
    static func current() -> DeviceStorageBreakdown? {
        guard
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage
        else {
            return nil
        }
        let totalCapacity = Int64(total)
        let appUsed = DownloadFileStore.totalSizeOnDisk()
        let otherUsed = max(0, totalCapacity - available - appUsed)
        return DeviceStorageBreakdown(totalCapacity: totalCapacity, appUsed: appUsed, otherUsed: otherUsed, free: available)
    }
}
