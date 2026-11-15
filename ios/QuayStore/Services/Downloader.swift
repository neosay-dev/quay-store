import Foundation

/// Downloads an IPA into Paths.ipas with progress.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    static let shared = Downloader()

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 60 * 60
        c.httpAdditionalHeaders = ["User-Agent": "QuayStore"]
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    private struct Pending {
        let destination: URL
        let progress: (Double) -> Void
        let continuation: CheckedContinuation<URL, Error>
    }

    private var pending: [Int: Pending] = [:]
    private let lock = NSLock()

    func download(_ url: URL, to fileName: String, progress: @escaping (Double) -> Void) async throws -> URL {
        let destination = Paths.ipas.appendingPathComponent(fileName)
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                pending[task.taskIdentifier] = Pending(destination: destination, progress: progress, continuation: cont)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func take(_ id: Int) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let p = pending[downloadTask.taskIdentifier]
        lock.unlock()
        p?.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let p = take(downloadTask.taskIdentifier) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            p.continuation.resume(throwing: QuayMessage("Сервер ответил \(http.statusCode) при скачивании"))
            return
        }
        do {
            try? FileManager.default.removeItem(at: p.destination)
            try FileManager.default.moveItem(at: location, to: p.destination)
            p.continuation.resume(returning: p.destination)
        } catch {
            p.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let p = take(task.taskIdentifier) else { return }
        if (error as? URLError)?.code == .cancelled {
            p.continuation.resume(throwing: CancellationError())
        } else {
            p.continuation.resume(throwing: error)
        }
    }
}
