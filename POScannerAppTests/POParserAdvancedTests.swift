//
//  POParserAdvancedTests.swift
//  POScannerAppTests
//

import Testing
import Foundation
@testable import POScannerApp

struct POParserAdvancedTests {
    @Test func parsesMultiLineItemWithPNQtyAndCost() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        ACME AUTO PARTS
        Brake Pad Set PN:BP-123
        Qty: 2
        $129.99
        """)

        #expect(parsed.vendorName == "ACME AUTO PARTS")
        #expect(!parsed.items.isEmpty)

        let item = parsed.items[0]
        #expect(item.quantity == 2)
        #expect(item.costCents == 12999)
        #expect(item.partNumber == "BP-123")
        #expect(item.confidence >= 0.8)
    }

    @Test func parsesInlineEAQtyPartAndCost() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: "Oil Filter XG7317 3 EA 29.97")

        #expect(parsed.vendorName == nil)
        #expect(!parsed.items.isEmpty)

        let item = parsed.items[0]
        #expect(item.quantity == 3)
        #expect(item.costCents == 2997)
        #expect(item.partNumber == "XG7317")
        #expect(item.confidence >= 0.6)
    }

    @Test func weakInputProducesLowConfidenceDefaults() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: "Widget")

        #expect(parsed.vendorName == nil)
        #expect(parsed.items.isEmpty)
    }

    @Test func classifiesMixedPartTireAndFeeRows() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Metro Auto Parts Supply
        Invoice INV-8831
        Front Brake Pad Set BP-123 Qty: 2 $89.99
        Michelin All Season Tire 225/45R17 Qty: 4 $110.00
        Shipping Freight $45.00
        Tax $12.00
        """)

        #expect(parsed.items.count >= 3)
        let parts = parsed.items.filter { $0.kind == .part }
        let tires = parsed.items.filter { $0.kind == .tire }
        let fees = parsed.items.filter { $0.kind == .fee }

        #expect(!parts.isEmpty)
        #expect(!tires.isEmpty)
        #expect(!fees.isEmpty)
        #expect(tires.first?.kindConfidence ?? 0 >= 0.75)
    }

    @Test func classifiesMountAndBalanceServiceAsFee() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Metro Auto Parts Supply
        Mount and Balance Service Qty: 4 $120.00
        """)

        #expect(parsed.items.count == 1)
        guard let item = parsed.items.first else { return }
        #expect(item.kind == .fee)
        #expect(item.kindConfidence >= 0.55)
    }

    @Test func parsesTableRowUnitPricesAndDocumentIdentifiers() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        METRO AUTO PARTS SUPPLY
        Invoice #: PO-99012 PO Number: MAP-45821
        ACD-41-993 Front Brake Pad Set - Ceramic 6 $68.00 $408.00
        MOOG-K750012 Front Sway Bar Link Kit 4 $45.00 $180.00
        FRM-PH7317 Engine Oil Filter 12 $9.50 $114.00
        DENSO-471-1635 A/C Compressor Assembly 2 $385.00 $770.00
        MICH-123 225/60/16 Primacy Michelin 4 $180.00 $720.00
        Shipping: $45.00
        Tax (8.5%): $125.12
        Total Amount Due: $1,642.12
        """, ignoreTaxAndTotals: true)

        #expect(parsed.invoiceNumber == "MAP-45821")
        #expect(parsed.poNumber == "PO-99012")
        #expect(parsed.items.count == 6)

        guard let brakePads = parsed.items.first(where: { $0.partNumber == "ACD-41-993" }) else {
            Issue.record("Missing brake pad row")
            return
        }
        #expect(brakePads.quantity == 6)
        #expect(brakePads.costCents == 6800)

        guard let tire = parsed.items.first(where: { $0.partNumber == "MICH-123" }) else {
            Issue.record("Missing tire row")
            return
        }
        #expect(tire.quantity == 4)
        #expect(tire.costCents == 18000)
        #expect(tire.kind == .tire)

        guard let shipping = parsed.items.first(where: { $0.name.lowercased().contains("shipping") }) else {
            Issue.record("Missing shipping row")
            return
        }
        #expect(shipping.costCents == 4500)
        #expect(shipping.kind == .fee)
    }

    @Test func doesNotTreatHeaderLabelsAsDocumentIdentifiers() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        METRO AUTO PARTS SUPPLY
        Invoice #:
        MAP-45821
        PO Number:
        PO-99012
        Vendor:
        METRO AUTO PARTS SUPPLY
        ACD-41-993 Front Brake Pad Set - Ceramic 6 $68.00 $408.00
        """)

        #expect(parsed.invoiceNumber == "MAP-45821")
        #expect(parsed.poNumber == "PO-99012")
    }

    @Test func filtersLaborLinesButKeepsFeeAndParts() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Advance Auto Parts
        Alignment Service Labor 1.5 hr $119.99
        BRAKEPAD-FR-887 Front Ceramic Brake Pad Set Qty: 1 $112.45
        Tire Disposal Fee Qty: 4 $6.00
        """)

        #expect(parsed.items.count == 2)
        #expect(parsed.items.contains(where: { $0.name.localizedCaseInsensitiveContains("Brake Pad") }))
        #expect(parsed.items.contains(where: { $0.name.localizedCaseInsensitiveContains("Disposal") }))
        #expect(!parsed.items.contains(where: { $0.name.localizedCaseInsensitiveContains("Alignment Service Labor") }))
    }

    @Test func filtersWheelAlignmentServiceLine() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Advance Auto Parts
        4-Wheel Alignment Service $119.99
        BRAKEPAD-FR-887 Front Ceramic Brake Pad Set Qty: 1 $112.45
        """)

        #expect(parsed.items.count == 1)
        #expect(parsed.items.first?.partNumber == "BRAKEPAD-FR-887")
        #expect(!parsed.items.contains(where: { $0.name.localizedCaseInsensitiveContains("Alignment") }))
    }

    @Test func ignoresTableHeaderRowsWithoutItems() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Qty  Part #  Description  Brand  Unit ($)  Ext ($)
        """, ignoreTaxAndTotals: true)

        #expect(parsed.items.isEmpty)
    }

    @Test func ignoresPickupLocationHeaderNoiseInTabularOCR() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Advance Auto Parts - Online Cart
        Qty Part # Description Unit ($) Pickup Location: Raleigh #1423 Ext ($)
        BRAKEPAD-FR-887 Front Ceramic Brake Pad Set CarQuest 1 $112.45
        """, ignoreTaxAndTotals: true)

        #expect(parsed.items.count == 1)
        guard let item = parsed.items.first else { return }
        #expect(item.partNumber == "BRAKEPAD-FR-887")
        #expect(item.costCents == 11245)
    }

    @Test func classifiesShopAndEnvironmentalFeeTokensAsFee() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Advance Auto Parts
        SHOP-FEE 1 Shop Supplies Fee $18.50
        ENV-FEE 1 Environmental Charge Fee $4.25
        """, ignoreTaxAndTotals: true)

        #expect(parsed.items.count == 2)
        #expect(parsed.items.allSatisfy { $0.kind == .fee })
    }

    @Test func classifiesBatteryLineAsPartWhenTireSignalsExistNearby() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Advance Auto Parts
        BAT-H7-AGM AGM Battery H7 850CCA DieHard Gold Qty: 1 $219.95
        225/65R17 Tire Falken Qty: 4 $164.00
        """, ignoreTaxAndTotals: true)

        guard let battery = parsed.items.first(where: { ($0.partNumber ?? "").contains("BAT-H7-AGM") }) else {
            Issue.record("Missing battery row")
            return
        }

        #expect(battery.kind == .part || battery.kind == .unknown)
        #expect(battery.kind != .tire)
    }

    @Test func prefersHyphenatedPartTokenOverCapacitySuffix() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Advance Auto Parts
        DieHard Gold AGM Battery H7 850CCA BAT-H7-AGM Qty: 1 $219.95
        """, ignoreTaxAndTotals: true)

        #expect(parsed.items.count == 1)
        guard let item = parsed.items.first else { return }
        #expect(item.partNumber == "BAT-H7-AGM")
        #expect(item.kind == .part || item.kind == .unknown)
        #expect(item.kind != .tire)
    }

    @Test func avoidsServiceCodeAsPartNumberWhenSpecificPartCodeExists() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        Advance Auto Parts
        Dorman TPMS Sensor 433MHz TPMS-433 ALIGN-4WHL Qty: 1 $52.00
        """, ignoreTaxAndTotals: true)

        #expect(parsed.items.count == 1)
        guard let item = parsed.items.first else { return }
        #expect(item.partNumber == "TPMS-433")
        #expect(item.kind == .part)
    }

    @Test func parsesRockAutoShipmentStyleScreenshotWithoutPriceColumns() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        ROCKAUTO Help Order Status & Returns Cart Menu
        Shipped
        Warehouse A Tracking: 426667372807
        2016 SUBARU OUTBACK 3.6L H6
        Drivetrain : CV Axle
        TOP NOTCH TN15002PR
        Front
        (Premium) Performance
        2 Quantity
        Arrange a Return / Report a Problem
        Warehouse B Tracking: 1ZB36H830330963840
        2005 SUBARU FORESTER 2.5L H4
        Transmission-Manual : Clutch Kit
        LUK 15031
        Includes Bearing Retainer Repair Sleeve
        1 Quantity
        Transmission-Manual : Flywheel
        LUK LFW262
        (Solid Flywheel)
        1 Quantity
        """, ignoreTaxAndTotals: true)

        #expect(parsed.items.count >= 2)
        #expect(parsed.items.contains(where: { $0.partNumber == "TN15002PR" }))
        #expect(parsed.items.contains(where: { ($0.partNumber ?? "").contains("LFW262") }))
    }

    @Test func parsesRockAutoShipmentStatusViewWithCardNoise() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        ROCKAUTO
        Help
        Order Status & Returns
        Cart
        Menu
        Shipped
        Warehouse A Tracking: 426667372807
        2016 SUBARU OUTBACK 3.6L H6
        Drivetrain : CV Axle
        TOP NOTCH TN15002PR Info
        Front
        (Premium) Performance
        2 Quantity
        Arrange a Return / Report a Problem
        Warehouse B Tracking: 1ZB36H830330963840
        2005 SUBARU FORESTER 2.5L H4
        Transmission-Manual : Clutch Kit
        LUK 15031 Info
        Includes Bearing Retainer Repair Sleeve and Matching Release Bearing.
        1 Quantity
        Transmission-Manual : Flywheel
        LUK LFW262 Info
        (Solid Flywheel)
        1 Quantity
        """, ignoreTaxAndTotals: true)

        #expect(parsed.vendorName == "RockAuto")
        #expect(parsed.items.count >= 2)
        #expect(parsed.items.contains(where: { ($0.partNumber ?? "").contains("TN15002PR") }))
        #expect(parsed.items.contains(where: { ($0.partNumber ?? "").contains("LFW262") }))
    }

    @Test func parsesRockAutoOrderConfirmationTableRows() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        RockAuto Order Confirmation
        Order 336879779
        2005 SUBARU FORESTER 2.5L H4
        LUK 15031 (15-031) Clutch Kit $ 185.79 $ 0.00 1 $ 185.79
        LUK LFW262 Flywheel $ 72.79 $ 0.00 1 $ 72.79
        2016 SUBARU OUTBACK 3.6L H6
        TOP NOTCH TN15002PR CV Axle $ 102.79 $ 0.00 2 $ 205.58
        Shipping Ground $ 27.98
        Tax $ 35.68
        Order Total $ 527.82
        """, ignoreTaxAndTotals: true)

        #expect(parsed.invoiceNumber == "336879779")
        guard let axle = parsed.items.first(where: { ($0.partNumber ?? "").contains("TN15002PR") }) else {
            Issue.record("Missing TN15002PR axle row")
            return
        }
        #expect(axle.quantity == 2)
        #expect(axle.costCents == 10279)
        #expect(parsed.items.contains(where: { ($0.partNumber ?? "").contains("LFW262") }))
    }

    @Test func parsesRockAutoOrderConfirmationScreenshotDetailView() async throws {
        let parser = POParser()
        let parsed = parser.parse(from: """
        RockAuto Order Confirmation
        Order 336879779
        Saturday, February 14, 2026 09:14 AM Central Time
        Ship To:
        Michael Bordeaux
        505 W HOLDING AVE
        Wake Forest, NC 27587-2846
        United States
        9197248425
        travers_fidget.2t@icloud.com
        Bill To:
        Michael Bordeaux
        505 W HOLDING AVE
        Wake Forest, NC 27587-2846
        United States
        9197248425
        travers_fidget.2t@icloud.com
        Part Number Part Type Price EA Core EA Quantity Total
        2005 SUBARU FORESTER 2.5L H4
        LUK 15031 (15-031) Clutch Kit $ 185.79 $ 0.00 1 $ 185.79
        LUK LFW262 Flywheel $ 72.79 $ 0.00 1 $ 72.79
        2016 SUBARU OUTBACK 3.6L H6
        TOP NOTCH TN15002PR CV Axle $ 102.79 $ 0.00 2 $ 205.58
        Shipping Ground $ 27.98
        Tax $ 35.68
        Order Total $ 527.82
        Gift Certificate or Store Credit ***********BDF4 -$ 527.82
        Balance Due $ 0.00
        """, ignoreTaxAndTotals: true)

        #expect(parsed.vendorName == "RockAuto")
        #expect(parsed.invoiceNumber == "336879779")
        #expect(parsed.header.vendorPhone == "9197248425")
        #expect(parsed.header.vendorEmail == "travers_fidget.2t@icloud.com")
        #expect(parsed.items.count >= 3)

        guard let axle = parsed.items.first(where: { ($0.partNumber ?? "").contains("TN15002PR") }) else {
            Issue.record("Missing TN15002PR axle row")
            return
        }
        #expect(axle.quantity == 2)
        #expect(axle.costCents == 10279)
        #expect(axle.name.localizedCaseInsensitiveContains("axle"))

        #expect(parsed.items.contains(where: { ($0.partNumber ?? "").contains("LFW262") }))
        #expect(!parsed.items.contains(where: { $0.name.localizedCaseInsensitiveContains("Gift Certificate") }))
        #expect(!parsed.items.contains(where: { $0.name.localizedCaseInsensitiveContains("Balance Due") }))
    }
}
