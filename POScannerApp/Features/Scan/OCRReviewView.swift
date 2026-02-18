//
//  OCRReviewView.swift
//  POScannerApp
//

import SwiftUI
import UIKit

struct OCRReviewView: View {
    let draft: ScanViewModel.OCRReviewDraft
    let onCancel: () -> Void
    let onContinue: (_ reviewedText: String, _ includeDetectedBarcodes: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reviewedText: String
    @State private var includeDetectedBarcodes: Bool = false
    @State private var showTextHighlights: Bool = true
    @State private var showBarcodeHighlights: Bool = true
    @State private var selectedLineID: OCRService.RecognizedLine.ID?
    @State private var selectedBarcodeID: OCRService.DetectedBarcode.ID?
    @State private var searchText: String = ""

    init(
        draft: ScanViewModel.OCRReviewDraft,
        onCancel: @escaping () -> Void,
        onContinue: @escaping (_ reviewedText: String, _ includeDetectedBarcodes: Bool) -> Void
    ) {
        self.draft = draft
        self.onCancel = onCancel
        self.onContinue = onContinue
        _reviewedText = State(initialValue: draft.extraction.text)
    }

    var body: some View {
        List {
            Section("Document Preview") {
                OCROverlayPreview(
                    image: draft.image,
                    lines: filteredLines,
                    barcodes: draft.extraction.barcodes,
                    selectedLineID: selectedLineID,
                    selectedBarcodeID: selectedBarcodeID,
                    showTextHighlights: showTextHighlights,
                    showBarcodeHighlights: showBarcodeHighlights
                )
                .frame(height: 280)

                Toggle("Highlight recognized text", isOn: $showTextHighlights)
                Toggle("Highlight barcodes", isOn: $showBarcodeHighlights)
            }

            if !draft.extraction.barcodes.isEmpty {
                Section("Detected Barcodes") {
                    Toggle("Include barcodes as parse hints", isOn: $includeDetectedBarcodes)

                    ForEach(draft.extraction.barcodes) { barcode in
                        Button {
                            selectedBarcodeID = barcode.id
                            appendBarcode(barcode)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(barcode.payload)
                                    .font(.body.monospaced())
                                Text("\(barcode.symbology) • \(Int((barcode.confidence * 100).rounded()))%")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ocr.barcode.\(barcode.payload)")
                    }
                }
            }

            Section("Recognized Text Lines") {
                if draft.extraction.lines.isEmpty {
                    Text("No text lines were recognized.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredLines) { line in
                        Button {
                            selectedLineID = line.id
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.text)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text("\(Int((line.confidence * 100).rounded()))% confidence")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedLineID == line.id {
                                    Image(systemName: "target")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Editable OCR Text") {
                NativeTextView(
                    text: $reviewedText,
                    placeholder: "Review and edit OCR text before parsing.",
                    accessibilityIdentifier: "ocr.reviewText"
                )
                .frame(minHeight: 220)

                Text("Tip: Tap a barcode above to append it, then continue to parse.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .nativeListSurface()
        .searchable(text: $searchText, prompt: "Filter lines")
        .navigationTitle("Review OCR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Parse") {
                    onContinue(reviewedText, includeDetectedBarcodes)
                    dismiss()
                }
                .disabled(reviewedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("ocr.parseButton")
            }
        }
    }

    private var filteredLines: [OCRService.RecognizedLine] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return draft.extraction.lines }
        return draft.extraction.lines.filter { line in
            line.text.localizedCaseInsensitiveContains(query)
        }
    }

    private func appendBarcode(_ barcode: OCRService.DetectedBarcode) {
        let suffix = "[BARCODE \(barcode.symbology)] \(barcode.payload)"
        let trimmed = reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            reviewedText = suffix
        } else if !reviewedText.contains(suffix) {
            reviewedText += "\n\(suffix)"
        }
    }
}

private struct OCROverlayPreview: View {
    let image: UIImage
    let lines: [OCRService.RecognizedLine]
    let barcodes: [OCRService.DetectedBarcode]
    let selectedLineID: OCRService.RecognizedLine.ID?
    let selectedBarcodeID: OCRService.DetectedBarcode.ID?
    let showTextHighlights: Bool
    let showBarcodeHighlights: Bool

    @State private var zoomScale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                if showTextHighlights {
                    ForEach(lines) { line in
                        let rect = rectInView(for: line.boundingBox, in: proxy.size)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(selectedLineID == line.id ? Color.blue : Color.yellow, lineWidth: selectedLineID == line.id ? 2 : 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill((selectedLineID == line.id ? Color.blue : Color.yellow).opacity(0.14))
                            )
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }

                if showBarcodeHighlights {
                    ForEach(barcodes) { barcode in
                        let rect = rectInView(for: barcode.boundingBox, in: proxy.size)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(selectedBarcodeID == barcode.id ? Color.green : Color.teal, lineWidth: selectedBarcodeID == barcode.id ? 2 : 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill((selectedBarcodeID == barcode.id ? Color.green : Color.teal).opacity(0.16))
                            )
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .scaleEffect(zoomScale * gestureScale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .gesture(
                MagnificationGesture()
                    .updating($gestureScale) { value, state, _ in
                        state = value
                    }
                    .onEnded { value in
                        zoomScale = min(4, max(1, zoomScale * value))
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy(duration: 0.2)) {
                    zoomScale = 1
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func rectInView(for normalized: CGRect, in containerSize: CGSize) -> CGRect {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        let drawRect: CGRect
        if imageAspect > containerAspect {
            let width = containerSize.width
            let height = width / imageAspect
            drawRect = CGRect(x: 0, y: (containerSize.height - height) / 2, width: width, height: height)
        } else {
            let height = containerSize.height
            let width = height * imageAspect
            drawRect = CGRect(x: (containerSize.width - width) / 2, y: 0, width: width, height: height)
        }

        return CGRect(
            x: drawRect.minX + (normalized.minX * drawRect.width),
            y: drawRect.minY + ((1 - normalized.maxY) * drawRect.height),
            width: normalized.width * drawRect.width,
            height: normalized.height * drawRect.height
        )
    }
}

#if DEBUG
#Preview("OCR Review") {
    NavigationStack {
        OCRReviewView(
            draft: .init(
                image: UIImage(systemName: "doc.text.viewfinder") ?? UIImage(),
                extraction: OCRService.DocumentExtraction(
                    text: "ACD-41-993 Front Brake Pad Set - Ceramic\nMICH-123 225/60/16 Primacy Michelin",
                    lines: [
                        OCRService.RecognizedLine(
                            text: "ACD-41-993 Front Brake Pad Set - Ceramic",
                            confidence: 0.92,
                            boundingBox: CGRect(x: 0.12, y: 0.62, width: 0.74, height: 0.07)
                        ),
                        OCRService.RecognizedLine(
                            text: "MICH-123 225/60/16 Primacy Michelin",
                            confidence: 0.88,
                            boundingBox: CGRect(x: 0.14, y: 0.49, width: 0.70, height: 0.07)
                        )
                    ],
                    barcodes: [
                        OCRService.DetectedBarcode(
                            payload: "MICH-123",
                            symbology: "CODE128",
                            confidence: 0.95,
                            boundingBox: CGRect(x: 0.15, y: 0.29, width: 0.55, height: 0.10)
                        )
                    ]
                ),
                ignoreTaxAndTotals: true
            ),
            onCancel: {},
            onContinue: { _, _ in }
        )
    }
}
#endif
