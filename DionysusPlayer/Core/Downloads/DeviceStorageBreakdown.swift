import Foundation

/// A three-bucket storage snapshot — This App, Other, Free — behind
/// `DeviceStorageBarView`. Coarse by necessity: no API surfaces per-app or
/// per-media-type usage to a regular app, so this only claims to know its own
/// slice rather than reproducing iOS Settings' breakdown.
struct DeviceStorageBreakdown {
    let totalCapacity: Int64
    /// This app's downloaded video, image and subtitle footprint, from
    /// `DownloadFileStore.totalSizeOnDisk()`.
    let appUsed: Int64
    /// Derived as `totalCapacity - free - appUsed`, not measured: iOS gives a
    /// regular app no API for other apps' usage.
    let otherUsed: Int64
    let free: Int64

    var used: Int64 { appUsed + otherUsed }

    /// Reads device capacity from the app's container volume. `nil` when the
    /// capacity keys aren't readable — not expected on a real device, but they
    /// are `Optional` in the API, and `DownloadsSettingsView` then falls back to
    /// a plain "Storage Used" figure with no graph.
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
