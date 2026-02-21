//
//  OCRService.swift
//  POScannerApp
//

import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Vision

/// OCR helper. The scanner path returns already-recognized text; image OCR is included for future expansion.
final class OCRService {
    enum OCRServiceError: Error {
        case noResults
    }

    struct RecognizedLine: Identifiable, Hashable {
        let id: UUID = UUID()
        let text: String
        let confidence: Double
        /// Vision normalized bounding box in image coordinates (origin at bottom-left).
        let boundingBox: CGRect
    }

    struct DetectedBarcode: Identifiable, Hashable {
        let id: UUID = UUID()
        let payload: String
        let symbology: String
        let confidence: Double
        /// Vision normalized bounding box in image coordinates (origin at bottom-left).
        let boundingBox: CGRect
    }

    struct DocumentExtraction: Hashable {
        let text: String
        let lines: [RecognizedLine]
        let barcodes: [DetectedBarcode]
    }

    private struct ColumnStats {
        var index: Int
        var numericCount: Int = 0
        var decimalCount: Int = 0
        var textCount: Int = 0
    }

    private let recognitionLanguages: [String]
    private let maxRecognizedLines: Int
    private let maxExtractedCharacters: Int

    init(
        recognitionLanguages: [String] = ["en-US"],
        maxRecognizedLines: Int = 400,
        maxExtractedCharacters: Int = 32_000
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.maxRecognizedLines = max(50, maxRecognizedLines)
        self.maxExtractedCharacters = max(4_000, maxExtractedCharacters)
    }

    func extractText(from scannerText: String) async throws -> String {
        try await extractDocument(from: scannerText).text
    }

    func extractDocument(from scannerText: String) async throws -> DocumentExtraction {
        // Preserve line structure but normalize whitespace on each line.
        let lines = scannerText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let recognized = lines.map { line in
            RecognizedLine(
                text: line,
                confidence: 1.0,
                boundingBox: .zero
            )
        }

        return DocumentExtraction(
            text: lines.joined(separator: "\n"),
            lines: recognized,
            barcodes: []
        )
    }

    func extractText(from cgImage: CGImage) async throws -> String {
        try await extractText(from: cgImage, orientation: .up)
    }

    func extractText(from cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> String {
        try await extractDocument(from: cgImage, orientation: orientation).text
    }

    func extractDocument(from cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> DocumentExtraction {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let textRequest = VNRecognizeTextRequest()
                    textRequest.recognitionLevel = .accurate
                    textRequest.usesLanguageCorrection = true
                    textRequest.recognitionLanguages = self.recognitionLanguages

                    let barcodeRequest = VNDetectBarcodesRequest()

                    let safeImage = OCRService.downscaleIfNeeded(cgImage)
                    let handler = VNImageRequestHandler(cgImage: safeImage, orientation: orientation, options: [:])
                    try handler.perform([textRequest, barcodeRequest])

                    let textObservations = (textRequest.results ?? [])
                        .sorted { $0.boundingBox.minY > $1.boundingBox.minY }

                    let clusteredRows = OCRService.clusterLinesByRow(textObservations)
                    let rawRows: [[String]] = clusteredRows.map { row in
                        row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }

                    let roles = OCRService.inferColumnRoles(from: rawRows)
                    let normalizedLines: [RecognizedLine] = clusteredRows.compactMap { row in
                        let sortedRow = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                        var rowTexts: [String] = []
                        var confidences: [Double] = []
                        for observation in sortedRow {
                            guard let candidate = observation.topCandidates(1).first else { continue }
                            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            rowTexts.append(text)
                            confidences.append(Double(candidate.confidence))
                        }

                        let normalizedText = OCRService.normalizedRowString(from: rowTexts, roles: roles)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalizedText.isEmpty else { return nil }

                        let confidence = confidences.isEmpty ? 0 : (confidences.reduce(0, +) / Double(confidences.count))
                        return RecognizedLine(
                            text: normalizedText,
                            confidence: confidence,
                            boundingBox: OCRService.unionBoundingBox(for: sortedRow)
                        )
                    }
                    .prefix(self.maxRecognizedLines)
                    .map { $0 }

                    let fullText = normalizedLines
                        .map(\.text)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")

                    let barcodeObservations = barcodeRequest.results ?? []
                    let barcodes = OCRService.extractBarcodes(from: barcodeObservations)

                    let barcodeText = barcodes
                        .map { "[BARCODE \($0.symbology)] \($0.payload)" }
                        .joined(separator: "\n")
                    let assembledText = fullText.isEmpty ? barcodeText : fullText
                    let boundedText = assembledText.count > self.maxExtractedCharacters
                        ? String(assembledText.prefix(self.maxExtractedCharacters))
                        : assembledText

                    guard !boundedText.isEmpty else {
                        continuation.resume(throwing: OCRServiceError.noResults)
                        return
                    }

                    continuation.resume(
                        returning: DocumentExtraction(
                            text: boundedText,
                            lines: normalizedLines,
                            barcodes: barcodes
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func downscaleIfNeeded(_ cgImage: CGImage) -> CGImage {
        let maxDimension: CGFloat = 2000

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let largestSide = max(width, height)

        guard largestSide > maxDimension, width > 0, height > 0 else { return cgImage }

        let scale = maxDimension / largestSide
        let newSize = CGSize(width: max(1, width * scale), height: max(1, height * scale))

        let newWidth = Int(newSize.width.rounded(.down))
        let newHeight = Int(newSize.height.rounded(.down))

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let supportsAlpha: Bool = {
            switch cgImage.alphaInfo {
            case .first, .last, .premultipliedFirst, .premultipliedLast:
                return true
            default:
                return false
            }
        }()

        // Use a broadly compatible pixel format for OCR. If this fails, fall back to the original image.
        let alphaInfo: CGImageAlphaInfo = supportsAlpha ? .premultipliedLast : .noneSkipLast
        let bitmapInfo = alphaInfo.rawValue
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return cgImage
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: newSize))
        return context.makeImage() ?? cgImage
    }

    private static func clusterLinesByRow(_ observations: [VNRecognizedTextObservation]) -> [[VNRecognizedTextObservation]] {
        let sorted = observations.sorted {
            $0.boundingBox.minY > $1.boundingBox.minY
        }

        var rows: [[VNRecognizedTextObservation]] = []
        let rowThreshold: CGFloat = 0.02

        for observation in sorted {
            if let lastRow = rows.last,
               let first = lastRow.first,
               abs(first.boundingBox.minY - observation.boundingBox.minY) < rowThreshold {
                rows[rows.count - 1].append(observation)
            } else {
                rows.append([observation])
            }
        }

        return rows
    }

    private static func inferColumnRoles(from rows: [[String]]) -> (description: Int?, quantity: Int?, price: Int?) {
        var columnStats: [Int: ColumnStats] = [:]

        for row in rows {
            for (index, cell) in row.enumerated() {
                var stats = columnStats[index] ?? ColumnStats(index: index)

                let normalizedNumeric = normalizedNumericCellValue(from: cell)
                if let normalizedNumeric, Double(normalizedNumeric) != nil {
                    stats.numericCount += 1
                    if normalizedNumeric.contains(".") {
                        stats.decimalCount += 1
                    }
                } else {
                    stats.textCount += 1
                }

                columnStats[index] = stats
            }
        }

        let quantityColumn = columnStats.values.max(by: {
            $0.numericCount < $1.numericCount
        })?.index

        let priceColumn = columnStats.values.max(by: {
            $0.decimalCount < $1.decimalCount
        })?.index

        let descriptionColumn = columnStats.values.max(by: {
            $0.textCount < $1.textCount
        })?.index

        return (description: descriptionColumn, quantity: quantityColumn, price: priceColumn)
    }

    private static func normalizedNumericCellValue(from cell: String) -> String? {
        let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Preserve minus sign and decimal point, strip common currency/formatting tokens.
        let cleaned = trimmed
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "(", with: "-")
            .replacingOccurrences(of: ")", with: "")

        let filtered = cleaned.filter { character in
            character.isNumber || character == "." || character == "-"
        }

        guard !filtered.isEmpty else { return nil }
        // Reject pathological values with multiple decimals or sign markers.
        guard filtered.filter({ $0 == "." }).count <= 1 else { return nil }
        guard filtered.filter({ $0 == "-" }).count <= 1 else { return nil }
        if filtered.contains("-"), filtered.first != "-" {
            return nil
        }
        return filtered
    }

    private static func normalizedRowString(
        from row: [String],
        roles: (description: Int?, quantity: Int?, price: Int?)
    ) -> String {
        guard !row.isEmpty else { return "" }

        var parts: [String] = []
        var consumed: Set<Int> = []

        if let descriptionIndex = roles.description,
           row.indices.contains(descriptionIndex) {
            parts.append(row[descriptionIndex])
            consumed.insert(descriptionIndex)
        }

        for (index, cell) in row.enumerated() where !consumed.contains(index) {
            let isQuantityColumn = (roles.quantity == index)
            let isPriceColumn = (roles.price == index)
            if isQuantityColumn || isPriceColumn {
                continue
            }
            parts.append(cell)
            consumed.insert(index)
        }

        if let quantityIndex = roles.quantity,
           row.indices.contains(quantityIndex),
           !consumed.contains(quantityIndex) {
            let quantityCell = row[quantityIndex]
            if quantityCell.range(of: #"^\d+$"#, options: .regularExpression) != nil {
                parts.append("Qty: \(quantityCell)")
            } else {
                parts.append(quantityCell)
            }
            consumed.insert(quantityIndex)
        }

        if let priceIndex = roles.price,
           row.indices.contains(priceIndex),
           !consumed.contains(priceIndex) {
            parts.append(row[priceIndex])
            consumed.insert(priceIndex)
        }

        return parts.joined(separator: " ")
    }

    private static func unionBoundingBox(for observations: [VNRecognizedTextObservation]) -> CGRect {
        let union = observations.reduce(into: CGRect.null) { partial, observation in
            partial = partial.union(observation.boundingBox)
        }
        return union.isNull ? .zero : union
    }

    private static func extractBarcodes(from observations: [VNBarcodeObservation]) -> [DetectedBarcode] {
        var seen = Set<String>()
        return observations.compactMap { observation in
            let payload = observation.payloadStringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !payload.isEmpty else { return nil }

            let symbology = observation.symbology.rawValue.uppercased()
            let key = "\(symbology)|\(payload)"
            guard seen.insert(key).inserted else { return nil }

            return DetectedBarcode(
                payload: payload,
                symbology: symbology,
                confidence: Double(observation.confidence),
                boundingBox: observation.boundingBox
            )
        }
    }
}
