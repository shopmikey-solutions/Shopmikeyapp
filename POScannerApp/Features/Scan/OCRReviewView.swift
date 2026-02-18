//
//  OCRReviewView.swift
//  POScannerApp
//

import SwiftUI
import UIKit

struct OCRReviewView: View {
    private struct EditableRecognizedLine: Identifiable, Hashable {
        let id: OCRService.RecognizedLine.ID
        var text: String
        let confidence: Double
    }

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
    @State private var editableLines: [EditableRecognizedLine]
    @State private var isEditingLines: Bool = false
    @State private var hasManualTextEdits: Bool = false
    @State private var hasLineEdits: Bool = false
    @State private var lastProgrammaticReviewedText: String?
    @State private var lockListScroll: Bool = false

    init(
        draft: ScanViewModel.OCRReviewDraft,
        onCancel: @escaping () -> Void,
        onContinue: @escaping (_ reviewedText: String, _ includeDetectedBarcodes: Bool) -> Void
    ) {
        self.draft = draft
        self.onCancel = onCancel
        self.onContinue = onContinue
        let initialText = draft.extraction.text
        _reviewedText = State(initialValue: initialText)
        _lastProgrammaticReviewedText = State(initialValue: initialText)
        _editableLines = State(
            initialValue: draft.extraction.lines.map { line in
                EditableRecognizedLine(
                    id: line.id,
                    text: line.text,
                    confidence: line.confidence
                )
            }
        )
    }

    var body: some View {
        List {
            Section("Document Preview") {
                OCROverlayPreview(
                    image: draft.image,
                    lines: overlayLines,
                    barcodes: draft.extraction.barcodes,
                    selectedLineID: selectedLineID,
                    selectedBarcodeID: selectedBarcodeID,
                    showTextHighlights: showTextHighlights,
                    showBarcodeHighlights: showBarcodeHighlights,
                    lockParentScroll: $lockListScroll
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
                            AppHaptics.selection()
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

            Section {
                if editableLines.isEmpty {
                    Text("No text lines were recognized.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredEditableLines) { line in
                        if isEditingLines {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField("Recognized text", text: bindingForLine(id: line.id), axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                    Text("\(Int((line.confidence * 100).rounded()))% confidence")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Button(role: .destructive) {
                                    AppHaptics.warning()
                                    deleteLine(id: line.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("ocr.deleteLine.\(line.id.uuidString)")
                            }
                        } else {
                            Button {
                                AppHaptics.selection()
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
                                            .foregroundStyle(AppSurfaceStyle.info)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recognized Text Lines")
                    Spacer()
                    if !editableLines.isEmpty {
                        Button(isEditingLines ? "Done" : "Edit") {
                            AppHaptics.selection()
                            withAnimation(.snappy(duration: 0.2)) {
                                isEditingLines.toggle()
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } footer: {
                if hasManualTextEdits && hasLineEdits {
                    Button("Apply line edits to OCR text") {
                        hasManualTextEdits = false
                        syncReviewedTextFromLinesIfNeeded(force: true)
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
        .scrollDisabled(lockListScroll)
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .tabBar)
        .searchable(text: $searchText, prompt: "Filter lines")
        .onChange(of: reviewedText) { _, newValue in
            if lastProgrammaticReviewedText == newValue {
                lastProgrammaticReviewedText = nil
            } else {
                hasManualTextEdits = true
            }
        }
        .navigationTitle("Review Invoice Capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    AppHaptics.selection()
                    onCancel()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Parse") {
                    AppHaptics.impact(.medium, intensity: 0.85)
                    onContinue(reviewedText, includeDetectedBarcodes)
                    dismiss()
                }
                .disabled(reviewedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("ocr.parseButton")
            }
        }
    }

    private var filteredEditableLines: [EditableRecognizedLine] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return editableLines }
        return editableLines.filter { line in
            line.text.localizedCaseInsensitiveContains(query)
        }
    }

    private var overlayLines: [OCRService.RecognizedLine] {
        let visibleIDs = Set(filteredEditableLines.map(\.id))
        return draft.extraction.lines.filter { visibleIDs.contains($0.id) }
    }

    private var joinedEditableLineText: String {
        editableLines
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func bindingForLine(id: OCRService.RecognizedLine.ID) -> Binding<String> {
        Binding(
            get: {
                editableLines.first(where: { $0.id == id })?.text ?? ""
            },
            set: { newValue in
                guard let index = editableLines.firstIndex(where: { $0.id == id }) else { return }
                editableLines[index].text = newValue
                hasLineEdits = true
                syncReviewedTextFromLinesIfNeeded()
            }
        )
    }

    private func deleteLine(id: OCRService.RecognizedLine.ID) {
        editableLines.removeAll { $0.id == id }
        if selectedLineID == id {
            selectedLineID = nil
        }
        hasLineEdits = true
        syncReviewedTextFromLinesIfNeeded()
    }

    private func syncReviewedTextFromLinesIfNeeded(force: Bool = false) {
        guard force || !hasManualTextEdits else { return }
        let updatedText = joinedEditableLineText
        lastProgrammaticReviewedText = updatedText
        reviewedText = updatedText
    }

    private func appendBarcode(_ barcode: OCRService.DetectedBarcode) {
        let suffix = "[BARCODE \(barcode.symbology)] \(barcode.payload)"
        let trimmed = reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            hasManualTextEdits = true
            reviewedText = suffix
        } else if !reviewedText.contains(suffix) {
            hasManualTextEdits = true
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
    @Binding var lockParentScroll: Bool

    @State private var zoomScale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @GestureState private var gesturePanOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let combinedScale = max(1, min(4, zoomScale * gestureScale))
            let combinedOffset = clampedOffset(
                CGSize(
                    width: panOffset.width + gesturePanOffset.width,
                    height: panOffset.height + gesturePanOffset.height
                ),
                scale: combinedScale,
                containerSize: proxy.size
            )

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                if showTextHighlights {
                    ForEach(lines) { line in
                        let rect = rectInView(for: line.boundingBox, in: proxy.size)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(
                                selectedLineID == line.id ? AppSurfaceStyle.info : AppSurfaceStyle.warning,
                                lineWidth: selectedLineID == line.id ? 2 : 1
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill((selectedLineID == line.id ? AppSurfaceStyle.info : AppSurfaceStyle.warning).opacity(0.14))
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
            .scaleEffect(combinedScale)
            .offset(x: combinedOffset.width, y: combinedOffset.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .highPriorityGesture(
                MagnificationGesture()
                    .updating($gestureScale) { value, state, _ in
                        state = value
                    }
                    .onEnded { value in
                        zoomScale = min(4, max(1, zoomScale * value))
                        if zoomScale <= 1.01 {
                            zoomScale = 1
                            panOffset = .zero
                        } else {
                            panOffset = clampedOffset(
                                panOffset,
                                scale: zoomScale,
                                containerSize: proxy.size
                            )
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($gesturePanOffset) { value, state, _ in
                        guard combinedScale > 1.01 else { return }
                        state = value.translation
                    }
                    .onEnded { value in
                        guard zoomScale > 1.01 else {
                            panOffset = .zero
                            return
                        }
                        panOffset = clampedOffset(
                            CGSize(
                                width: panOffset.width + value.translation.width,
                                height: panOffset.height + value.translation.height
                            ),
                            scale: zoomScale,
                            containerSize: proxy.size
                        )
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy(duration: 0.2)) {
                    if zoomScale > 1.01 {
                        zoomScale = 1
                        panOffset = .zero
                    } else {
                        zoomScale = 2
                    }
                }
            }
            .onChange(of: combinedScale) { _, newValue in
                lockParentScroll = newValue > 1.01
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDisappear {
            lockParentScroll = false
        }
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

    private func clampedOffset(_ offset: CGSize, scale: CGFloat, containerSize: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let maxX = (containerSize.width * (scale - 1)) / 2
        let maxY = (containerSize.height * (scale - 1)) / 2
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
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
