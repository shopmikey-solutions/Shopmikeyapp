//
//  POParserTests.swift
//  POScannerAppTests
//

import Testing
import ShopmikeyCoreParsing
import ShopmikeyCoreModels
@testable import POScannerApp

struct POParserTests {
    @Test func extractsPONumber() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        ACME Auto Parts
        PO: 12345
        2 Brake Pads $19.99
        """)

        #expect(parsed.poNumber == "12345")
    }

    @Test func extractsLineItems() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        ACME Auto Parts
        PO #AB-123
        2 Brake Pads $19.99
        1 Oil Filter $5.50
        """)

        #expect(parsed.items.count == 2)
        #expect(parsed.items[0].quantity == 2)
        #expect(parsed.items[0].costCents == 1999)
        #expect(parsed.items[0].name.contains("Brake"))
    }

    @Test func extractsVendorNameFallbackFromHeader() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        ACME Auto Parts
        Purchase Order
        PO: 12345
        """)

        #expect(parsed.vendorName == "ACME Auto Parts")
    }

    @Test func extractsInvoiceNumber() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        ACME Auto Parts
        Invoice No. INV-2026-001
        2 Brake Pads $19.99
        """)

        #expect(parsed.invoiceNumber == "INV-2026-001")
    }

    @Test func extractsVendorContactDetailsFromHeader() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        ACME Auto Parts
        Contact: 800-555-1212
        Email: parts@acme.example
        Invoice INV-301
        1 Brake Pad Set $79.99
        """)

        #expect(parsed.header.vendorPhone == "800-555-1212")
        #expect(parsed.header.vendorEmail == "parts@acme.example")
    }
}
