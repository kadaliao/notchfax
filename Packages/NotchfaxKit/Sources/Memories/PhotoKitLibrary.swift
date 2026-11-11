import AppKit
import os
import Photos

/// The person's Photos library.
struct PhotoKitLibrary: MemoryLibrary {
    let name = "照片图库"

    func access() -> MemoryAccess {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> MemoryAccess {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    @concurrent
    func candidates(in windows: [DateInterval]) async throws -> [MemoryCandidate] {
        guard access().canRead else { throw MemoryLibraryError.notAuthorized }
        guard !windows.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: windows.map {
            NSPredicate(format: "creationDate >= %@ AND creationDate < %@", $0.start as NSDate, $0.end as NSDate)
        })
        // The person's own pictures: not shared albums, not hidden ones, one frame per burst.
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var candidates: [MemoryCandidate] = []
        candidates.reserveCapacity(result.count)
        for index in 0..<result.count {
            let asset = result.object(at: index)
            guard let date = asset.creationDate else { continue }
            candidates.append(MemoryCandidate(
                id: asset.localIdentifier,
                date: date,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                isFavorite: asset.isFavorite,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                hasAdjustments: asset.hasAdjustments,
                burstIdentifier: asset.burstIdentifier
            ))
        }
        return candidates
    }

    @concurrent
    func image(for candidate: MemoryCandidate, maxPixel: Int, timeout: Duration) async throws -> CGImage {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.id], options: nil).firstObject else {
            throw MemoryLibraryError.imageUnavailable
        }
        let longSide = Double(max(1, asset.pixelWidth, asset.pixelHeight))
        let factor = min(1, Double(maxPixel) / longSide)
        let target = CGSize(width: (Double(asset.pixelWidth) * factor).rounded(), height: (Double(asset.pixelHeight) * factor).rounded())

        let options = PHImageRequestOptions()
        // Originals kept only in iCloud are downloaded; a local preview arrives first and
        // stands in if the download is too slow.
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.version = .current

        let request = ImageRequest(minimumFallbackSide: min(maxPixel, 640))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.begin(continuation)
                let id = PHImageManager.default().requestImage(
                    for: asset, targetSize: target, contentMode: .aspectFit, options: options
                ) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    if degraded {
                        request.offerPreview(cgImage)
                    } else {
                        request.finish(cgImage)
                    }
                }
                request.attach(id)
                Task {
                    try? await Task.sleep(for: timeout)
                    request.timeOut()
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> MemoryAccess {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}

/// One image request to Photos, resumed exactly once whichever of "done", "timed out"
/// or "cancelled" happens first.
private final class ImageRequest: Sendable {
    private struct State {
        var continuation: CheckedContinuation<CGImage, any Error>?
        var preview: CGImage?
        var requestID: PHImageRequestID?
        var isDone = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let minimumFallbackSide: Int

    init(minimumFallbackSide: Int) {
        self.minimumFallbackSide = minimumFallbackSide
    }

    func begin(_ continuation: CheckedContinuation<CGImage, any Error>) {
        let alreadyCancelled = state.withLock { state -> Bool in
            if state.isDone { return true }
            state.continuation = continuation
            return false
        }
        if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
    }

    func attach(_ id: PHImageRequestID) {
        let cancelNow = state.withLock { state -> Bool in
            state.requestID = id
            return state.isDone
        }
        if cancelNow { PHImageManager.default().cancelImageRequest(id) }
    }

    func offerPreview(_ image: CGImage?) {
        guard let image, max(image.width, image.height) >= minimumFallbackSide else { return }
        state.withLock { if !$0.isDone { $0.preview = image } }
    }

    func finish(_ image: CGImage?) {
        complete { preview in
            if let image { return .success(image) }
            if let preview { return .success(preview) }
            return .failure(MemoryLibraryError.imageUnavailable)
        }
    }

    func timeOut() {
        let cancelled = complete { preview in
            preview.map { .success($0) } ?? .failure(MemoryLibraryError.timedOut)
        }
        if let cancelled { PHImageManager.default().cancelImageRequest(cancelled) }
    }

    func cancel() {
        let cancelled = complete { _ in .failure(CancellationError()) }
        if let cancelled { PHImageManager.default().cancelImageRequest(cancelled) }
    }

    /// Resumes the continuation once; returns the request to cancel, if any.
    @discardableResult
    private func complete(_ result: (CGImage?) -> Result<CGImage, any Error>) -> PHImageRequestID? {
        let taken = state.withLock { state -> (CheckedContinuation<CGImage, any Error>?, CGImage?, PHImageRequestID?)? in
            guard !state.isDone else { return nil }
            state.isDone = true
            defer {
                state.continuation = nil
                state.preview = nil
            }
            return (state.continuation, state.preview, state.requestID)
        }
        guard let (continuation, preview, id) = taken else { return nil }
        continuation?.resume(with: result(preview))
        return id
    }
}
