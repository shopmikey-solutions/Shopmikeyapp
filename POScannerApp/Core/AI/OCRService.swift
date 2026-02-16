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

    private struct ColumnStats {
        var index: Int
        var numericCount: Int = 0
        var decimalCount: Int = 0
        var textCount: Int = 0
    }

    func extractText(from scannerText: String) async throws -> String {
        // Preserve line structure but normalize whitespace on each line.
        let lines = scannerText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    func extractText(from cgImage: CGImage) async throws -> String {
        try await extractText(from: cgImage, orientation: .up)
    }

    func extractText(from cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                let clusteredRows = self.clusterLinesByRow(observations)
                let rows = clusteredRows.map { row in
                    row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                        .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }

                let roles = self.inferColumnRoles(from: rows)
                let rowStrings = rows
                    .map { self.normalizedRowString(from: $0, roles: roles) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                let fullText = rowStrings
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                guard !fullText.isEmpty else {
                    continuation.resume(throwing: OCRServiceError.noResults)
                    return
                }
                continuation.resume(returning: fullText)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let safeImage = OCRService.downscaleIfNeeded(cgImage)
                    let handler = VNImageRequestHandler(cgImage: safeImage, orientation: orientation, options: [:])
                    try handler.perform([request])
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

        // Use a broadly compatible pixel format for OCR. If this fails, fall back to the original image.
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
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

    private func clusterLinesByRow(_ observations: [VNRecognizedTextObservation]) -> [[VNRecognizedTextObservation]] {
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

    private func inferColumnRoles(from rows: [[String]]) -> (description: Int?, quantity: Int?, price: Int?) {
        var columnStats: [Int: ColumnStats] = [:]

        for row in rows {
            for (index, cell) in row.enumerated() {
                var stats = columnStats[index] ?? ColumnStats(index: index)

                if Double(cell.replacingOccurrences(of: ",", with: "")) != nil {
                    stats.numericCount += 1
                    if cell.contains(".") {
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

    private func normalizedRowString(
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
}
