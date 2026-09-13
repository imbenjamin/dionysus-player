import Foundation

/// A request that transferred without a transport error but returned a non-2xx
/// status. See `urlSession(_:downloadTask:didFinishDownloadingTo:)`.
enum DownloadTransferError: LocalizedError {
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return String(localized: "The server returned an error (HTTP \(code)) instead of the video.")
        }
    }
}

/// The single `URLSessionDownloadDelegate` behind the app's one background
/// `URLSession`, routing callbacks to `DownloadManager` by the itemID carried
/// on each task. Also the delegate for the session re-created when the app
/// relaunches into the background to finish delivering queued callbacks.
///
/// One session per app is Apple's model, and departing from it is what made
/// downloads fragile: a session per item meant an XPC channel and
/// `nsurlsessiond` store entry each, churned on every completion — which
/// invalidated one session and built another in the same main-actor turn,
/// asynchronously, so teardown and setup overlapped. The daemon eventually
/// dropped the connection with `NSURLErrorBackgroundSessionWasDisconnected`
/// (-997). That churn scaled with how many items passed through the queue
/// rather than how many ran at once, so Max Simultaneous Downloads never
/// affected it.
///
/// `@unchecked Sendable`: `URLSession` calls a `delegateQueue: nil` delegate on
/// a private serial queue, so the lock below satisfies Swift 6's checking
/// rather than resolving real contention.
final class DownloadTaskRouter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Set by `DownloadManager` after construction, before the session exists
    /// to deliver anything. `var`s rather than `init` parameters to break the
    /// cycle between the manager and its router.
    var onProgress: (@MainActor (String, Int64, Int64) -> Void)?
    var onCompletion: (@MainActor (String, Result<Void, Error>) -> Void)?
    var onFinishedEvents: (@MainActor () -> Void)?

    private let lock = NSLock()
    /// Task identifiers already reported through `onCompletion`.
    private var reportedTaskIdentifiers: Set<Int> = []

    /// Which download a callback belongs to. `taskDescription` holds the itemID
    /// and a background session persists it across an app relaunch, so it
    /// survives the OS waking the app to deliver a transfer finished while
    /// suspended.
    private func itemID(for task: URLSessionTask) -> String? {
        task.taskDescription
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let itemID = itemID(for: downloadTask), let onProgress else { return }
        Task { @MainActor in onProgress(itemID, totalBytesWritten, totalBytesExpectedToWrite) }
    }

    /// Fires on transfer success, before `didCompleteWithError`. `location` is a
    /// temp file the system deletes when this returns, so the move into
    /// `DownloadFileStore` must happen synchronously here, not in a `Task`.
    ///
    /// The status check is load-bearing: `URLSessionDownloadTask` calls this
    /// whenever the transfer completes, whatever the status code, so an error
    /// response would otherwise land as a `.completed` row backed by an
    /// unplayable file — worse than a visible failure.
    ///
    /// The destination is derived, not captured, since one router serves every
    /// download. `DownloadFileStore.videoRelativePath(itemID:)` is pure and
    /// matches what `enqueue` stores in `videoFilePath`; the equivalence is
    /// pinned by `DownloadManagerTests.test_videoFilePathMatchesRouterDerivedPath`.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let itemID = itemID(for: downloadTask), let onCompletion else { return }
        markReported(downloadTask.taskIdentifier)
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor in onCompletion(itemID, .failure(DownloadTransferError.badStatus(http.statusCode))) }
            return
        }
        do {
            try DownloadFileStore.moveFile(from: location, toRelativePath: DownloadFileStore.videoRelativePath(itemID: itemID))
            Task { @MainActor in onCompletion(itemID, .success(())) }
        } catch {
            Task { @MainActor in onCompletion(itemID, .failure(error)) }
        }
    }

    /// Reports failures only; success already resolved via
    /// `didFinishDownloadingTo`.
    ///
    /// The two are not mutually exclusive: a task can deliver its file and then
    /// complete with an error, and the failure lands second, so it would win
    /// the row's status write and flip a `.completed` download to `.failed`.
    /// `reportedTaskIdentifiers` settles that on the serial delegate queue,
    /// before either report crosses to the main actor. `DownloadManager` guards
    /// the same hazard independently, failing in a different direction.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let alreadyReported = clearReported(task.taskIdentifier)
        guard let error, !alreadyReported else { return }
        guard let itemID = itemID(for: task), let onCompletion else { return }
        Task { @MainActor in onCompletion(itemID, .failure(error)) }
    }

    /// Called once every queued callback has been delivered after a relaunch:
    /// the signal to answer UIKit's completion handler, without which the OS
    /// treats the app as still busy and reclaims its background time.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let onFinishedEvents else { return }
        Task { @MainActor in onFinishedEvents() }
    }

    private func markReported(_ taskIdentifier: Int) {
        lock.lock()
        defer { lock.unlock() }
        reportedTaskIdentifiers.insert(taskIdentifier)
    }

    /// Removes and returns whether the identifier was present. A task completes
    /// once, so this also stops the set growing for the process lifetime.
    private func clearReported(_ taskIdentifier: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reportedTaskIdentifiers.remove(taskIdentifier) != nil
    }
}
