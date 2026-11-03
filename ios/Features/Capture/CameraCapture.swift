import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor enum CameraCapturePermission {
    static func request(bundle: Bundle = .main) async throws {
        guard let usage = bundle.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              UIImagePickerController.isSourceTypeAvailable(.camera) else { throw ScanFailure.unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw ScanFailure.permissionDenied }
        default: throw ScanFailure.permissionDenied
        }
    }
}
/// Still photo only; no microphone, library write, video or background capture.
@MainActor struct CameraCaptureView: UIViewControllerRepresentable {
    let authorize: () -> Bool
    let onResult: (Result<Data, ScanFailure>?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIViewController {
        guard authorize(), UIImagePickerController.isSourceTypeAvailable(.camera), AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            Task { @MainActor in onResult(.failure(.unavailable)) }
            return UIViewController()
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera; picker.cameraCaptureMode = .photo
        picker.mediaTypes = [UTType.image.identifier]; picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.parent = self
    }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraCaptureView
        private var delivered = false
        init(_ parent: CameraCaptureView) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard parent.authorize() else { finish(.failure(.stale)); return }
            guard let image = info[.originalImage] as? UIImage, let cg = image.cgImage,
                  cg.height > 0, cg.width <= 30_000_000 / cg.height,
                  let data = image.jpegData(compressionQuality: 0.9), data.count <= CaptureLimits.imageBytes else {
                finish(.failure(.tooLarge)); return
            }
            finish(.success(data))
        }
        private func finish(_ result: Result<Data, ScanFailure>?) {
            guard !delivered else { return }; delivered = true; parent.onResult(result)
        }
    }
}
