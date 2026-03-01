//
//  TicketStoreTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@Suite(.serialized)
struct TicketStoreTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ticket_store_tests", isDirectory: true)
            .appendingPathComponent("\(name)_\(UUID().uuidString).json", isDirectory: false)
    }

    @Test func saveAndLoadTicketRoundTripsAcrossInstances() async {
        let fileURL = temporaryURL("roundtrip")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = TicketStore(fileURL: fileURL)
        let updatedAt = Date(timeIntervalSince1970: 1_772_286_523)
        let ticket = TicketModel(
            id: "ticket_1",
            number: "RO-5001",
            displayNumber: "RO-5001",
            status: "Open",
            customerName: "Jordan Driver",
            vehicleSummary: "2019 Honda Civic",
            updatedAt: updatedAt,
            lineItems: [
                TicketLineItem(
                    id: "line_1",
                    kind: "part",
                    sku: "SKU-1",
                    partNumber: "PN-1",
                    description: "Brake Pad",
                    quantity: 2,
                    unitPrice: 59.95,
                    extendedPrice: 119.9,
                    vendorId: "vendor_1"
                )
            ]
        )

        await store.save(ticket: ticket)

        let reopened = TicketStore(fileURL: fileURL)
        let loaded = await reopened.loadTicket(id: "ticket_1")

        #expect(loaded?.id == "ticket_1")
        #expect(loaded?.number == "RO-5001")
        #expect(loaded?.customerName == "Jordan Driver")
        #expect(loaded?.lineItems.count == 1)
    }

    @Test func saveTicketsReplacesDatasetAndLoadOpenTicketsFiltersClosed() async {
        let fileURL = temporaryURL("replace")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = TicketStore(fileURL: fileURL)
        await store.save(tickets: [
            TicketModel(
                id: "open_1",
                number: "RO-1",
                status: "Open",
                updatedAt: Date(timeIntervalSince1970: 1_772_286_500)
            ),
            TicketModel(
                id: "closed_1",
                number: "RO-2",
                status: "Closed",
                updatedAt: Date(timeIntervalSince1970: 1_772_286_400)
            )
        ])

        var openTickets = await store.loadOpenTickets()
        #expect(openTickets.count == 1)
        #expect(openTickets.first?.id == "open_1")

        await store.save(tickets: [
            TicketModel(
                id: "open_2",
                number: "RO-3",
                status: "In Progress",
                updatedAt: Date(timeIntervalSince1970: 1_772_286_600)
            )
        ])

        openTickets = await store.loadOpenTickets()
        #expect(openTickets.count == 1)
        #expect(openTickets.first?.id == "open_2")
        #expect(await store.loadTicket(id: "open_1") == nil)
    }
}
