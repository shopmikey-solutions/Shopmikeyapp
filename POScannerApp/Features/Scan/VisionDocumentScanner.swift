//
//  VisionDocumentScanner.swift
//  POScannerApp
//

import ImageIO
import SwiftUI
import UIKit
import VisionKit

/// VisionKit document camera wrapper for scanning a paper invoice/PO into an image.
///
/// UIKit is used only here to host `VNDocumentCameraViewController`.
struct VisionDocumentScanner: UIViewControllerRepresentable {
    var onScan: (UIImage, CGImagePropertyOrientation) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {
        _ = uiViewController
        _ = context
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: (UIImage, CGImagePropertyOrientation) -> Void
        let onCancel: () -> Void
        private var didComplete = false

        init(
            onScan: @escaping (UIImage, CGImagePropertyOrientation) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            guard !didComplete else { return }
            didComplete = true

            guard scan.pageCount > 0 else {
                onCancel()
                return
            }

            Task { @MainActor in
                AppHaptics.success()
            }

            DispatchQueue.global(qos: .userInitiated).async { [onScan] in
                // Use first page for now.
                let image = scan.imageOfPage(at: 0)
                let orientation = image.imageOrientation.cgImagePropertyOrientation
                DispatchQueue.main.async {
                    onScan(image, orientation)
                }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            guard !didComplete else { return }
            didComplete = true
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            _ = error
            guard !didComplete else { return }
            didComplete = true
            onCancel()
        }
    }
}

extension UIImage.Orientation {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up:
            return .up
        case .down:
            return .down
        case .left:
            return .left
        case .right:
            return .right
        case .upMirrored:
            return .upMirrored
        case .downMirrored:
            return .downMirrored
        case .leftMirrored:
            return .leftMirrored
        case .rightMirrored:
            return .rightMirrored
        @unknown default:
            return .up
        }
    }
}
