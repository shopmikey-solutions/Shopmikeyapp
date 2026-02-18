//
//  LocalParseHandoffServiceTests.swift
//  POScannerAppTests
//

import CoreGraphics
import Testing
@testable import POScannerApp

struct LocalParseHandoffServiceTests {
    @Test func buildsCompactModelInputWithHighSignalRows() async throws {
        let service = LocalParseHandoffService()

        let payload = service.build(
            reviewedText: """
            METRO AUTO PARTS SUPPLY
            Invoice #: MAP-45821
            PO Number: PO-99012
            ACD-41-993 Front Brake Pad Set Qty: 6 $68.00
            MICH-123 225/60/16 Primacy Michelin Qty: 4 $180.00
            Shipping $45.00
            TERMS AND CONDITIONS APPLY
            ACD-41-993 Front Brake Pad Set Qty: 6 $68.00
            """,
            barcodeHints: []
        )

        #expect(payload.metrics.rawLineCount == 8)
        #expect(payload.metrics.deduplicatedLineCount == 7)
        #expect(payload.metrics.modelCharacterCount <= payload.metrics.rulesCharacterCount)
        #expect(payload.modelInputText.contains("Invoice #: MAP-45821"))
        #expect(payload.modelInputText.contains("PO Number: PO-99012"))
        #expect(payload.modelInputText.contains("MICH-123 225/60/16 Primacy Michelin"))
    }

    @Test func carriesBarcodeHintsWhenTextIsEmpty() async throws {
        let service = LocalParseHandoffService()

        let payload = service.build(
            reviewedText: "\n\n",
            barcodeHints: [
                OCRService.DetectedBarcode(
                    payload: "MICH-123",
                    symbology: "CODE128",
                    confidence: 0.99,
                    boundingBox: .zero
                )
            ]
        )

        #expect(payload.metrics.rawLineCount == 0)
        #expect(payload.metrics.barcodeCount == 1)
        #expect(payload.rulesInputText.contains("[BARCODE CODE128] MICH-123"))
        #expect(payload.modelInputText.contains("[BARCODE CODE128] MICH-123"))
        #expect(payload.hasModelInput)
    }

    @Test func enforcesModelBudgetLimits() async throws {
        let service = LocalParseHandoffService(
            maxRulesCharacters: 600,
            maxRulesLines: 50,
            maxModelCharacters: 80,
            maxModelLines: 2
        )

        let payload = service.build(
            reviewedText: """
            Vendor Name
            Invoice #: MAP-45821
            PO Number: PO-99012
            ACD-41-993 Front Brake Pad Set Qty: 6 $68.00
            MICH-123 225/60/16 Primacy Michelin Qty: 4 $180.00
            Shipping $45.00
            """,
            barcodeHints: []
        )

        #expect(payload.metrics.modelTrimmed)
        #expect(payload.metrics.modelLineCount <= 2)
        #expect(payload.metrics.modelCharacterCount <= 80)
    }
}
