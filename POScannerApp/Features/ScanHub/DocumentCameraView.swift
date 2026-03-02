//
//  DocumentCameraView.swift
//  POScannerApp
//

import SwiftUI
import UIKit
import VisionKit

struct DocumentCameraView: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentCameraView

        init(parent: DocumentCameraView) {
            self.parent = parent
        }

        @MainActor
        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [UIImage] = []
            pages.reserveCapacity(scan.pageCount)
            for index in 0..<scan.pageCount {
                pages.append(scan.imageOfPage(at: index))
            }

            guard !pages.isEmpty else {
                parent.onError("No pages were scanned.")
                controller.dismiss(animated: true)
                return
            }

            parent.onScan(pages)
            controller.dismiss(animated: true)
        }

        @MainActor
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
            controller.dismiss(animated: true)
        }

        @MainActor
        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            parent.onError(error.localizedDescription)
            controller.dismiss(animated: true)
        }
    }
}
