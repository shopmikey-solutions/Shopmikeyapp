//
//  TicketReconcileTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct TicketReconcileTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ticket_reconcile_tests", isDirectory: true)
            .appendingPathComponent("\(name)_\(UUID().uuidString).json", isDirectory: false)
    }

    @Test func matchingPriorityPrefersSKUOverPartNumberAndDescription() async {
        let fileURL = temporaryURL("priority_sku")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = TicketStore(fileURL: fileURL)
        await store.save(ticket: TicketModel(
            id: "ticket_1",
            status: "Open",
            lineItems: [
                TicketLineItem(
                    id: "line_sku",
                    sku: "sku-100",
                    partNumber: "pn-100",
                    description: "Brake Pad",
                    quantity: 1
                ),
                TicketLineItem(
                    id: "line_part",
                    sku: "sku-200",
                    partNumber: "pn-200",
                    description: "Rotor",
                    quantity: 1
                )
            ]
        ))

        let match = await store.findMatchingLineItem(
            ticketID: "ticket_1",
            sku: " SKU-100 ",
            partNumber: "PN-200",
            description: "Rotor"
        )
        #expect(match?.id == "line_sku")
    }

    @Test func matchingUsesPartNumberWhenSkuMissing() async {
        let fileURL = temporaryURL("priority_part")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = TicketStore(fileURL: fileURL)
        await store.save(ticket: TicketModel(
            id: "ticket_1",
            status: "Open",
            lineItems: [
                TicketLineItem(
                    id: "line_part",
                    partNumber: "pn-500",
                    description: "Oil Filter",
                    quantity: 1
                )
            ]
        ))

        let match = await store.findMatchingLineItem(
            ticketID: "ticket_1",
            sku: nil,
            partNumber: " PN-500 ",
            description: "Ignored"
        )
        #expect(match?.id == "line_part")
    }

    @Test func descriptionFallbackAppliesOnlyWhenIdentifiersAreMissing() async {
        let fileURL = temporaryURL("priority_description")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = TicketStore(fileURL: fileURL)
        await store.save(ticket: TicketModel(
            id: "ticket_1",
            status: "Open",
            lineItems: [
                TicketLineItem(
                    id: "line_description_only",
                    description: "Cabin Filter",
                    quantity: 1
                ),
                TicketLineItem(
                    id: "line_with_identifiers",
                    sku: "CAB-123",
                    description: "Cabin Filter",
                    quantity: 1
                )
            ]
        ))

        let fallbackMatch = await store.findMatchingLineItem(
            ticketID: "ticket_1",
            sku: nil,
            partNumber: nil,
            description: "  cabin filter  "
        )
        #expect(fallbackMatch?.id == "line_description_only")

        let identifierProvidedNoFallback = await store.findMatchingLineItem(
            ticketID: "ticket_1",
            sku: nil,
            partNumber: "NO-MATCH",
            description: "Cabin Filter"
        )
        #expect(identifierProvidedNoFallback == nil)
    }
}
