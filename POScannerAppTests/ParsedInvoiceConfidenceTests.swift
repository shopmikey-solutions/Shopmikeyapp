//
//  ParsedInvoiceConfidenceTests.swift
//  POScannerAppTests
//

import Testing
@testable import POScannerApp

struct ParsedInvoiceConfidenceTests {
    @Test func confidenceScoreMatchesLegacyFixtureValue() {
        let parsed = ParsedInvoice(
            vendorName: "Advance Auto Parts",
            poNumber: nil,
            invoiceNumber: "INV-1105",
            totalCents: nil,
            items: [
                ParsedLineItem(
                    name: "Front Brake Rotor",
                    quantity: 2,
                    costCents: 8990,
                    partNumber: "ROTOR-887F",
                    confidence: 0.8
                )
            ]
        )

        let legacyExpectedScore = 0.8 // vendor (0.3) + items (0.3) + invoice (0.2)
        #expect(abs(parsed.confidenceScore - legacyExpectedScore) < 0.000_000_1)
    }
}
