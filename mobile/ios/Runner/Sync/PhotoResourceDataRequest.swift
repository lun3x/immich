import Foundation
import Photos

// One streaming request owns its cancellation and first write error. A cancel
// arriving before PhotoKit returns its ID is applied as soon as the ID exists.
final class PhotoResourceDataRequest: @unchecked Sendable {
  private let lock = NSLock()
  private var requestId: PHAssetResourceDataRequestID?
  private var cancelled = false
  private var writeError: Error?

  func cancel() {
    lock.lock()
    cancelled = true
    let id = requestId
    lock.unlock()
    if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
  }

  private func setRequestId(_ id: PHAssetResourceDataRequestID) {
    lock.lock()
    requestId = id
    let shouldCancel = cancelled
    lock.unlock()
    if shouldCancel { PHAssetResourceManager.default().cancelDataRequest(id) }
  }

  private func resultError(_ error: Error?) -> Error? {
    lock.lock()
    defer { lock.unlock() }
    return writeError ?? (cancelled ? CancellationError() : error)
  }

  private func fail(_ error: Error) {
    lock.lock()
    if writeError == nil { writeError = error }
    lock.unlock()
    cancel()
  }

  func read(_ resource: PHAssetResource, allowNetworkAccess: Bool, consume: @escaping (Data) throws -> Void) async throws {
    try await withTaskCancellationHandler(operation: {
      if let error = resultError(nil) { throw error }
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetworkAccess
        let id = PHAssetResourceManager.default().requestData(
          for: resource,
          options: options,
          dataReceivedHandler: { [self] data in
            guard resultError(nil) == nil else { return }
            do { try consume(data) } catch { fail(error) }
          },
          completionHandler: { [self] error in
            if let error = resultError(error) {
              continuation.resume(throwing: error)
            } else {
              continuation.resume()
            }
          }
        )
        setRequestId(id)
      }
    }, onCancel: { self.cancel() })
  }
}
