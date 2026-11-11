import AVFoundation
import Foundation
import Photos

/// Asks for everything the app needs in one go on first launch, so the system
/// prompts do not interrupt a photo-booth sitting or the first morning print.
enum Permissions {
    static let defaultsKey = "permissions.requested"

    static func shouldRequest(launch: LaunchOptions) -> Bool {
        if launch.requestsPermissions { return true }
        if launch.isScripted { return false }
        return !UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Requests photo-library and camera access, one prompt after the other.
    /// Access already granted or refused is left alone.
    static func requestAll() async {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        UserDefaults.standard.set(true, forKey: defaultsKey)
    }

    static var summary: String {
        let photos = switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: "authorized"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
        let camera = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
        return "photos=\(photos) camera=\(camera)"
    }
}
