import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor enum CameraCapturePermission {
    static func request(bundle: Bundle = .main, presenting: PantryNotificationPresenter? = nil) async throws {
        guard let usage = bundle.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              UIImagePickerController.isSourceTypeAvailable(.camera) else { throw ScanFailure.unavailable }
        try await authorize(AVCaptureDevice.authorizationStatus(for: .video), presenting: presenting) {
            await AVCaptureDevice.requestAccess(for: .video)
        }
    }

    static func authorize(_ status: AVAuthorizationStatus, presenting: PantryNotificationPresenter?,
                          request: PantryNotificationRequest) async throws {
        switch status {
        case .authorized: return
        case .notDetermined:
            let granted: Bool
            if let presenting {
                granted = try await presenting(request)
            } else {
                granted = try await request()
            }
            guard granted else { throw ScanFailure.permissionDenied }
        default: throw ScanFailure.permissionDenied
        }
    }
}
/// Still photo only; no microphone, library write, video or background capture.
@MainActor struct CameraCaptureView: UIViewControllerRepresentable {
    struct PreviousReceiptEdge { let image: Data?; let wording: String }
    let authorize: () -> Bool
    var previousReceiptEdge: PreviousReceiptEdge? = nil
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
        if let previousReceiptEdge {
            let overlay = UIView(frame: picker.view.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.isUserInteractionEnabled = false
            let strip = UIStackView()
            strip.axis = .vertical; strip.spacing = 2
            strip.translatesAutoresizingMaskIntoConstraints = false
            strip.backgroundColor = UIColor.black.withAlphaComponent(0.75)
            if let data = previousReceiptEdge.image, let image = UIImage(data: data)?.cgImage {
                let height = max(1, image.height / 5)
                if let edge = image.cropping(to: CGRect(x: 0, y: image.height - height, width: image.width, height: height)) {
                    let ghost = UIImageView(image: UIImage(cgImage: edge))
                    ghost.contentMode = .scaleAspectFit
                    ghost.heightAnchor.constraint(equalToConstant: 48).isActive = true
                    ghost.isAccessibilityElement = false
                    strip.addArrangedSubview(ghost)
                }
            }
            let caption = UILabel()
            caption.numberOfLines = 2; caption.textAlignment = .center; caption.textColor = .white
            caption.font = .preferredFont(forTextStyle: .footnote); caption.adjustsFontForContentSizeCategory = true
            caption.text = captureText("Previous section ends with") + " · " + previousReceiptEdge.wording
            strip.addArrangedSubview(caption)
            overlay.addSubview(strip)
            NSLayoutConstraint.activate([
                strip.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 60),
                strip.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 16),
                strip.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -16)
            ])
            picker.cameraOverlayView = overlay
        }
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
