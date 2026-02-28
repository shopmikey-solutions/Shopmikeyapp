//
//  DocumentProfileStrategyTests.swift
//  POScannerAppTests
//

import Testing
import ShopmikeyCoreModels
@testable import POScannerApp

struct DocumentProfileStrategyTests {
    @Test func choosesSameEcommerceProfileForExistingCartFixture() {
        let parser = POParser()
        let profile = parser.governanceDocumentProfile(for: """
        MY CART (11)
        2016 Subaru Outback
        Denso Iridium TT Spark Plug - 4704
        Part # 4704 Line DEN
        - 6 + REMOVE
        $77.94
        FREE Pick Up
        Available within 24-48 hours.
        """)

        #expect(profile == .ecommerceCart)
    }

    @Test func choosesSameTabularInvoiceProfileForExistingInvoiceFixture() {
        let parser = POParser()
        let profile = parser.governanceDocumentProfile(for: """
        METRO AUTO PARTS SUPPLY
        Invoice #: PO-99012 PO Number: MAP-45821
        ACD-41-993 Front Brake Pad Set - Ceramic 6 $68.00 $408.00
        MOOG-K750012 Front Sway Bar Link Kit 4 $45.00 $180.00
        Tax (8.5%): $125.12
        Total Amount Due: $1,642.12
        """)

        #expect(profile == .tabularInvoice)
    }
}
