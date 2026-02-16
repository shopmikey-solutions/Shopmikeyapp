//
//  ScannerViewControllerWrapper.swift
//  POScannerApp
//

import SwiftUI
import UIKit
import VisionKit

/// Full-screen scanner wrapper. UIKit is used only here to host `DataScannerViewController`.
struct ScannerViewControllerWrapper: View {
    let onComplete: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recognizedText: String = ""

    var body: some View {
        ZStack(alignment: .top) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                DataScannerRepresentable(recognizedText: $recognizedText)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text("Scanner unavailable on this device.")
                        .font(.headline)
                    Text("You can still enter text manually in the Review screen once parsing is refined.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }

            headerBar
        }
    }

    private var headerBar: some View {
        HStack {
            Button("Cancel") {
                onComplete(nil)
                dismiss()
            }

            Spacer()

            Button("Done") {
                let text = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                onComplete(text.isEmpty ? nil : text)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    @Binding var recognizedText: String

    func makeUIViewController(context: Context) -> UIViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator

        do {
            try scanner.startScanning()
        } catch {
            return makeFallbackController()
        }

        return scanner
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // No-op. Scanning starts in `makeUIViewController`.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(recognizedText: $recognizedText)
    }

    private func makeFallbackController() -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = UIColor.systemBackground

        let label = UILabel()
        label.text = "Unable to start scanner."
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
        @Binding var recognizedText: String
        private var transcripts: [String] = []

        init(recognizedText: Binding<String>) {
            self._recognizedText = recognizedText
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            append(items: addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            append(items: updatedItems)
        }

        private func append(items: [RecognizedItem]) {
            for item in items {
                switch item {
                case .text(let text):
                    let line = text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty {
                        transcripts.append(line)
                    }
                default:
                    break
                }
            }

            recognizedText = joinedTranscripts(transcripts)
        }

        private func joinedTranscripts(_ transcripts: [String]) -> String {
            var seen = Set<String>()
            let deduped = transcripts.filter { seen.insert($0).inserted }
            return deduped.joined(separator: "\n")
        }
    }
}
