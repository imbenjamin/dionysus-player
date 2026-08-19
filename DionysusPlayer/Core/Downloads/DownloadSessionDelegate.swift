import Foundation

/// Handles one background `URLSessionDownloadTask` for a video download —
/// progress, completion (moves the temp file into place via
/// `DownloadFileStore`), and failure. One instance per active download,
/// created and retained by `DownloadManager` for the download's lifetime —
/// `URLSession` doesn't retain its own delegate. Also the target for a
/// re-attached session after the app relaunches into the background to
/// finish delivering queued callbacks (`urlSessionDidFinishEvents(
/// forBackgroundURLSession:)`) — see `AppDelegate.application(_:
/// handleEventsForBackgroundURLSession:completionHandler:)` and
/// `DownloadManager`'s matching reattachment.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private let destinationRelativePath: String
    private let onProgress: @MainActor (Int64, Int64) -> Void
    private let onCompletion: @MainActor (Result<Void, Error>) -> Void
    private let onFinishedEvents: @MainActor () -> Void

    init(
        destinationRelativePath: String,
        onProgress: @escaping @MainActor (Int64, Int64) -> Void,
        onCompletion: @escaping @MainActor (Result<Void, Error>) -> Void,
        onFinishedEvents: @escaping @MainActor () -> Void
    ) {
        self.destinationRelativePath = destinationRelativePath
        self.onProgress = onProgress
        self.onCompletion = onCompletion
        self.onFinishedEvents = onFinishedEvents
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let onProgress = onProgress
        Task { @MainActor in onProgress(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    /// Fires (only on success) before `didCompleteWithError` — `location`
    /// is a temp file the system deletes as soon as this method returns, so
    /// the move into `DownloadFileStore` has to happen synchronously here,
    /// not in a later `Task`.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let onCompletion = onCompletion
        do {
            try DownloadFileStore.moveFile(from: location, toRelativePath: destinationRelativePath)
            Task { @MainActor in onCompletion(.success(())) }
        } catch {
            Task { @MainActor in onCompletion(.failure(error)) }
        }
    }

    /// Only reports a *failure* here — a successful download already
    /// resolved via `didFinishDownloadingTo` above, and calling
    /// `onCompletion` a second time for the same task would double-report.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let onCompletion = onCompletion
        Task { @MainActor in onCompletion(.failure(error)) }
    }

    /// The system calls this once every queued delegate callback for a
    /// background session has been delivered after a relaunch — the signal
    /// to finally call the completion handler UIKit handed
    /// `AppDelegate.application(_:handleEventsForBackgroundURLSession:
    /// completionHandler:)`, or it assumes the app is still busy and can
    /// suspend it more aggressively/reclaim its background time.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let onFinishedEvents = onFinishedEvents
        Task { @MainActor in onFinishedEvents() }
    }
}
