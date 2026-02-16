//
//  ShopmonkeyOrderServiceTests.swift
//  POScannerAppTests
//

import Testing
@testable import POScannerApp

private struct StubShopmonkeyService: ShopmonkeyServicing {
    var orders: [OrderSummary] = []
    var servicesByOrderId: [String: [ServiceSummary]] = [:]
    var vendors: [VendorSummary] = []

    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        .init(id: "v_1", name: request.name)
    }

    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        _ = orderId
        _ = serviceId
        return .init(id: "p_1", name: request.name)
    }

    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] {
        []
    }

    func fetchOrders() async throws -> [OrderSummary] {
        orders
    }

    func fetchServices(orderId: String) async throws -> [ServiceSummary] {
        servicesByOrderId[orderId] ?? []
    }

    func searchVendors(name: String) async throws -> [VendorSummary] {
        _ = name
        return vendors
    }

    func testConnection() async throws {
        // Not used by picker tests.
    }
}

struct ShopmonkeyOrderServiceTests {
    @Test func fetchOrdersReturnsSampleOrders() async throws {
        let stub = StubShopmonkeyService(orders: [
            .init(id: "o_1", number: "1001", customerName: "Alice"),
            .init(id: "o_2", number: nil, customerName: "Bob")
        ])

        let orders = try await stub.fetchOrders()
        #expect(orders.count == 2)
        #expect(orders[0].displayTitle == "Order #1001")
        #expect(orders[1].displayTitle == "Order o_2")
    }

    @Test func fetchServicesReturnsSampleServices() async throws {
        let stub = StubShopmonkeyService(
            orders: [],
            servicesByOrderId: [
                "o_1": [
                    .init(id: "s_1", name: "Brakes"),
                    .init(id: "s_2", name: nil)
                ]
            ]
        )

        let services = try await stub.fetchServices(orderId: "o_1")
        #expect(services.count == 2)
        #expect(services[0].name == "Brakes")
        #expect(services[1].id == "s_2")
    }

    @Test func pickerSelectionUpdatesReviewViewModelIds() async throws {
        let stub = StubShopmonkeyService()
        let parsed = ParsedInvoice(vendorName: "ACME AUTO PARTS", poNumber: nil, items: [])

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: stub)
        }

        let order = OrderSummary(id: "o_1", number: "1001", customerName: "Alice")
        let service = ServiceSummary(id: "s_1", name: "Brakes")

        await MainActor.run {
            vm.selectOrder(order)
        }

        #expect(await MainActor.run { vm.orderId } == "o_1")
        #expect(await MainActor.run { vm.serviceId } == "")

        await MainActor.run {
            vm.selectService(service)
        }

        #expect(await MainActor.run { vm.serviceId } == "s_1")
    }

    @Test func selectingVendorSuggestionPersistsVendorIdForSubmission() async throws {
        let stub = StubShopmonkeyService()
        let parsed = ParsedInvoice(vendorName: nil, poNumber: nil, items: [])

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: stub)
        }

        let vendor = VendorSummary(id: "v_123", name: "ACME Parts")
        await MainActor.run {
            vm.selectVendorSuggestion(vendor)
        }

        #expect(await MainActor.run { vm.vendorName } == "ACME Parts")
        #expect(await MainActor.run { vm.submissionPayload.vendorId } == "v_123")

        await MainActor.run {
            vm.setVendorName("ACME Parts East")
        }

        #expect(await MainActor.run { vm.submissionPayload.vendorId } == nil)
    }
}
