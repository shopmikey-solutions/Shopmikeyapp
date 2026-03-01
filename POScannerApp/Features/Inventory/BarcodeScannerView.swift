//
//  BarcodeScannerView.swift
//  POScannerApp
//

import SwiftUI
import UIKit
import Vision
import VisionKit

struct BarcodeScannerView: View {
    static var isScannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    let onComplete: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var lastScannedCode: String = ""

    private var trimmedCode: String {
        lastScannedCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack(alignment: .top) {
            BarcodeScannerRepresentable(lastScannedCode: $lastScannedCode)
                .ignoresSafeArea()

            headerBar
        }
        .accessibilityIdentifier("inventory.barcodeScanner")
    }

    private var headerBar: some View {
        HStack {
            Button("Cancel") {
                onComplete(nil)
                dismiss()
            }
            .accessibilityIdentifier("inventory.barcodeScannerCancel")

            Spacer()

            Button("Use Code") {
                let codeToReturn = trimmedCode
                onComplete(codeToReturn.isEmpty ? nil : codeToReturn)
                dismiss()
            }
            .disabled(trimmedCode.isEmpty)
            .accessibilityIdentifier("inventory.barcodeScannerDone")
            .appPrimaryActionButton()
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

private struct BarcodeScannerRepresentable: UIViewControllerRepresentable {
    @Binding var lastScannedCode: String

    func makeUIViewController(context: Context) -> UIViewController {
        guard BarcodeScannerView.isScannerAvailable else {
            return makeFallbackController(message: "Scanner unavailable on this device.")
        }

        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean8, .ean13, .upce, .code128, .qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator

        do {
            try scanner.startScanning()
            return scanner
        } catch {
            return makeFallbackController(message: "Unable to start barcode scanner.")
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        _ = context
        guard let scanner = uiViewController as? DataScannerViewController else { return }
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            // Keep the current scanner surface stable; fallback handled at creation.
        }
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        _ = coordinator
        guard let scanner = uiViewController as? DataScannerViewController else { return }
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(lastScannedCode: $lastScannedCode)
    }

    private func makeFallbackController(message: String) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = UIColor.systemBackground

        let label = UILabel()
        label.text = message
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = UIColor.secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false

        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: controller.view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: controller.view.trailingAnchor, constant: -24)
        ])

        return controller
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        @Binding var lastScannedCode: String

        init(lastScannedCode: Binding<String>) {
            self._lastScannedCode = lastScannedCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            updateFromRecognizedItems(addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            updateFromRecognizedItems(updatedItems)
        }

        private func updateFromRecognizedItems(_ items: [RecognizedItem]) {
            for item in items {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !payload.isEmpty else {
                    continue
                }
                lastScannedCode = payload
                return
            }
        }
    }
}
