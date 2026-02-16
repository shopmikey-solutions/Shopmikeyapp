//
//  ReviewViewModelTests.swift
//  POScannerAppTests
//

import Testing
@testable import POScannerApp

private struct MinimalShopmonkeyService: ShopmonkeyServicing {
    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        .init(id: "v_1", name: request.name)
    }

    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        .init(id: "p_1", name: request.name)
    }

    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] { [] }
    func fetchOrders() async throws -> [OrderSummary] { [] }
    func fetchServices(orderId: String) async throws -> [ServiceSummary] { [] }
    func searchVendors(name: String) async throws -> [VendorSummary] {
        [VendorSummary(id: "v_1", name: "ACME Parts")]
    }
    func testConnection() async throws {}
}

struct ReviewViewModelTests {
    @Test func manualTypeOverridePersistsInSubmissionPayload() async throws {
        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: nil,
            items: [
                ParsedLineItem(
                    name: "Shipping line",
                    quantity: 1,
                    costCents: 1500,
                    partNumber: nil,
                    confidence: 0.8,
                    kind: .unknown,
                    kindConfidence: 0.1,
                    kindReasons: []
                )
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: MinimalShopmonkeyService())
        }

        await MainActor.run {
            let oldKind = vm.items[0].kind
            vm.items[0].kind = .fee
            vm.recordTypeOverride(from: oldKind, to: .fee)
        }

        let payloadKind = await MainActor.run { vm.submissionPayload.items.first?.kind }
        let overrideCount = await MainActor.run { vm.typeOverrideCount }
        #expect(payloadKind == .fee)
        #expect(overrideCount == 1)
    }

    @Test func unknownKindRateTracksCurrentItems() async throws {
        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: nil,
            items: [
                ParsedLineItem(name: "Line A", quantity: 1, costCents: 1000, partNumber: nil, confidence: 0.7, kind: .unknown, kindConfidence: 0.1, kindReasons: []),
                ParsedLineItem(name: "Line B", quantity: 1, costCents: 2000, partNumber: nil, confidence: 0.7, kind: .part, kindConfidence: 0.9, kindReasons: [])
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: MinimalShopmonkeyService())
        }

        let initialRate = await MainActor.run { vm.unknownKindRate }
        await MainActor.run {
            let oldKind = vm.items[0].kind
            vm.items[0].kind = .part
            vm.recordTypeOverride(from: oldKind, to: .part)
        }
        let updatedRate = await MainActor.run { vm.unknownKindRate }

        #expect(initialRate > 0)
        #expect(updatedRate == 0)
    }
}
