import Foundation

/// A transcode/stream request that transferred (no transport-level error)
/// but came back with a non-2xx HTTP status — see `DownloadTaskRouter
/// .urlSession(_:downloadTask:didFinishDownloadingTo:)`'s own doc comment
/// for the bug this exists to catch instead of silently succeeding.
enum DownloadTransferError: LocalizedError {
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return String(localized: "The server returned an error (HTTP \(code)) instead of the video.")
        }
    }
}

/// The **one** `URLSessionDownloadDelegate` behind the app's single
/// background `URLSession`, routing every callback back to
/// `DownloadManager` by the itemID carried on the task itself.
///
/// This replaced a per-download delegate paired with a per-download
/// background session whose identifier was `"com.dionysus.downloads." +
/// itemID`. That arrangement is what made downloads fragile: every
/// background session is its own XPC channel to `nsurlsessiond` plus its
/// own entry in that daemon's persistent store, and Apple's model is one
/// background session per app, created once and kept for the process
/// lifetime. Instead the app churned them — each completion invalidated one
/// session and, in the same main-actor turn, admitted the next queued item
/// and built another, with background-session invalidation being
/// asynchronous so teardown and setup overlapped. The daemon eventually
/// dropped the app's connection and returned
/// `NSURLErrorBackgroundSessionWasDisconnected` (-997), which reached the
/// user as a `.failed` row reading "Lost connection to the background
/// transfer service". Crucially that churn scales with how many items pass
/// *through* the queue, not with how many run at once, which is why the
/// Max Simultaneous Downloads setting made no difference to it.
///
/// Also the target for the session re-created after the app relaunches into
/// the background to finish delivering queued callbacks — see
/// `AppDelegate.application(_:handleEventsForBackgroundURLSession:
/// completionHandler:)` and `DownloadManager.handleBackgroundSessionEvents`.
///
/// `@unchecked Sendable`: `URLSession` calls a delegate created with
/// `delegateQueue: nil` on a private *serial* queue, so the lock below
/// guards state that is not in practice contended — it exists to satisfy
/// Swift 6's checking rather than to fix a real race, the same reasoning
/// `BackgroundSessionCompletionBox` records for its own annotation.
final class DownloadTaskRouter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Set once by `DownloadManager` immediately after construction, before
    /// the session that uses this router can exist to deliver anything.
    /// `var`s rather than `init` parameters purely to break the
    /// chicken-and-egg between the manager and its own router.
    var onProgress: (@MainActor (String, Int64, Int64) -> Void)?
    var onCompletion: (@MainActor (String, Result<Void, Error>) -> Void)?
    var onFinishedEvents: (@MainActor () -> Void)?

    private let lock = NSLock()
    /// Task identifiers already reported through `onCompletion`. See
    /// `urlSession(_:task:didCompleteWithError:)` for what this prevents.
    private var reportedTaskIdentifiers: Set<Int> = []

    /// Which download a callback belongs to. `taskDescription` is set to the
    /// itemID when the task is created and is persisted by a background
    /// session across an app relaunch, so it survives the exact case that
    /// matters most — the OS waking the app to deliver a transfer that
    /// finished while it was suspended.
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

    /// Fires (only on success *of the transfer itself*) before
    /// `didCompleteWithError` — `location` is a temp file the system
    /// deletes as soon as this method returns, so the move into
    /// `DownloadFileStore` has to happen synchronously here, not in a
    /// later `Task`. A real bug, found live (2026-08-20): this used to
    /// move whatever landed at `location` into place and report success
    /// completely unconditionally — `URLSessionDownloadTask` calls this
    /// method whenever the *transfer* completes, regardless of the HTTP
    /// status code, so a server error response (a 4xx/5xx with an empty or
    /// tiny error body, confirmed live: a mismatched-case transcode URL
    /// returning a 0-byte response) got silently treated as a successful
    /// download — a `.completed` row backed by a 0-byte, unplayable file,
    /// worse than a visible failure would have been. Now checks the
    /// response status first and reports a failure instead.
    ///
    /// The destination is *derived* here rather than captured, since one
    /// router serves every download: `DownloadFileStore
    /// .videoRelativePath(itemID:)` is a pure function of the itemID and is
    /// exactly what `DownloadManager.enqueue` stores in the row's
    /// `videoFilePath`. That equivalence is load-bearing and pinned by
    /// `DownloadManagerTests.test_videoFilePathMatchesRouterDerivedPath`.
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

    /// Only reports a *failure* here — a successful download already
    /// resolved via `didFinishDownloadingTo` above.
    ///
    /// The two are not mutually exclusive at the `URLSession` level: a task
    /// can deliver its file and *then* complete with an error, and because
    /// the failure report lands second it used to win the row's status
    /// write, flipping a genuinely `.completed` download to `.failed` with
    /// nothing having gone wrong. `reportedTaskIdentifiers` settles that
    /// here, on the serial delegate queue, before either report crosses to
    /// the main actor. `DownloadManager` carries an independent guard of its
    /// own for the same hazard — they fail in different directions, and this
    /// particular symptom is one that would masquerade convincingly as "the
    /// -997 fix didn't work".
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let alreadyReported = clearReported(task.taskIdentifier)
        guard let error, !alreadyReported else { return }
        guard let itemID = itemID(for: task), let onCompletion else { return }
        Task { @MainActor in onCompletion(itemID, .failure(error)) }
    }

    /// The system calls this once every queued delegate callback for the
    /// background session has been delivered after a relaunch — the signal
    /// to finally call the completion handler UIKit handed
    /// `AppDelegate.application(_:handleEventsForBackgroundURLSession:
    /// completionHandler:)`, or it assumes the app is still busy and can
    /// suspend it more aggressively/reclaim its background time.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let onFinishedEvents else { return }
        Task { @MainActor in onFinishedEvents() }
    }

    private func markReported(_ taskIdentifier: Int) {
        lock.lock()
        defer { lock.unlock() }
        reportedTaskIdentifiers.insert(taskIdentifier)
    }

    /// Removes and returns whether the identifier was present — a task is
    /// only ever completed once, so this both answers the question and stops
    /// the set growing for the process lifetime.
    private func clearReported(_ taskIdentifier: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reportedTaskIdentifiers.remove(taskIdentifier) != nil
    }
}
