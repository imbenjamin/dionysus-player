import Foundation

/// A transcode/stream request that transferred (no transport-level error)
/// but came back with a non-2xx HTTP status — see `DownloadSessionDelegate
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
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let onCompletion = onCompletion
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor in onCompletion(.failure(DownloadTransferError.badStatus(http.statusCode))) }
            return
        }
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
