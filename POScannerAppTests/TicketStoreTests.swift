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

    @Test func activeTicketSelectionPersistsAcrossInstances() async {
        let fileURL = temporaryURL("active_ticket")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = TicketStore(fileURL: fileURL)
        await store.save(tickets: [
            TicketModel(id: "ticket_1", number: "RO-1001", status: "Open"),
            TicketModel(id: "ticket_2", number: "RO-1002", status: "Open")
        ])
        await store.setActiveTicketID("ticket_2")

        let reopened = TicketStore(fileURL: fileURL)
        #expect(await reopened.activeTicketID() == "ticket_2")
    }

    @Test func clearingActiveTicketCanClearServiceContext() async {
        let fileURL = temporaryURL("clear_active_context")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = TicketStore(fileURL: fileURL)
        await store.save(tickets: [
            TicketModel(id: "ticket_1", number: "RO-2001", status: "Open")
        ])
        await store.setActiveTicketID("ticket_1")
        await store.setSelectedServiceID("service_1", forTicketID: "ticket_1")

        await store.setSelectedServiceID(nil, forTicketID: "ticket_1")
        await store.setActiveTicketID(nil)

        #expect(await store.activeTicketID() == nil)
        #expect(await store.loadActiveTicket() == nil)
        #expect(await store.selectedServiceID(forTicketID: "ticket_1") == nil)
    }

    @Test func applyAddedLineItemSupportsIncrementAndAddModes() async {
        let fileURL = temporaryURL("line_item_merge")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        let store = TicketStore(fileURL: fileURL)
        await store.save(ticket: TicketModel(
            id: "ticket_1",
            number: "RO-3001",
            status: "Open",
            lineItems: [
                TicketLineItem(
                    id: "line_1",
                    kind: "part",
                    sku: "PAD-001",
                    partNumber: "PAD-001",
                    description: "Brake Pad",
                    quantity: 1,
                    unitPrice: 50,
                    extendedPrice: 50,
                    vendorId: "vendor_1"
                )
            ]
        ))

        _ = await store.applyAddedLineItem(
            TicketLineItem(
                id: "line_new_1",
                kind: "part",
                sku: "PAD-001",
                partNumber: "PAD-001",
                description: "Brake Pad",
                quantity: 2,
                unitPrice: 50,
                extendedPrice: 100,
                vendorId: "vendor_1"
            ),
            toTicketID: "ticket_1",
            mergeMode: .incrementQuantity,
            updatedAt: Date(timeIntervalSince1970: 1_772_287_000)
        )

        let incremented = await store.loadTicket(id: "ticket_1")
        #expect(incremented?.lineItems.count == 1)
        #expect(NSDecimalNumber(decimal: incremented?.lineItems.first?.quantity ?? 0).doubleValue == 3)
        #expect(NSDecimalNumber(decimal: incremented?.lineItems.first?.extendedPrice ?? 0).doubleValue == 150)

        _ = await store.applyAddedLineItem(
            TicketLineItem(
                id: "line_new_2",
                kind: "part",
                sku: "PAD-001",
                partNumber: "PAD-001",
                description: "Brake Pad",
                quantity: 1,
                unitPrice: 50,
                extendedPrice: 50,
                vendorId: "vendor_1"
            ),
            toTicketID: "ticket_1",
            mergeMode: .addNewLine,
            updatedAt: Date(timeIntervalSince1970: 1_772_287_100)
        )

        let added = await store.loadTicket(id: "ticket_1")
        #expect(added?.lineItems.count == 2)
    }
}
