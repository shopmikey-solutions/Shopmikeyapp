//
//  VendorDedupTests.swift
//  POScannerAppTests
//

import CoreData
import ShopmikeyCoreDiagnostics
import ShopmikeyCoreModels
import Testing
import ShopmikeyCoreNetworking
@testable import POScannerApp

private final class RecordingShopmonkeyService: ShopmonkeyServicing, @unchecked Sendable {
    var searchCalls: Int = 0
    var createCalls: Int = 0
    var createPartCalls: Int = 0
    var partVendorIds: [String] = []

    var searchResults: [VendorSummary] = []
    var searchError: Error?
    var createdVendorId: String = "v_created"

    func searchVendors(name: String) async throws -> [VendorSummary] {
        _ = name
        searchCalls += 1
        if let searchError { throw searchError }
        return searchResults
    }

    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        createCalls += 1
        return CreateVendorResponse(id: createdVendorId, name: request.name)
    }

    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        _ = orderId
        _ = serviceId
        createPartCalls += 1
        partVendorIds.append(request.vendorId)
        return CreatePartResponse(id: "p_1", name: request.name)
    }

    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] {
        []
    }

    func fetchOrders() async throws -> [OrderSummary] {
        []
    }

    func fetchServices(orderId: String) async throws -> [ServiceSummary] {
        _ = orderId
        return []
    }

    func testConnection() async throws {
        // Not used by vendor de-dup tests.
    }
}

private func fetchVendors(in context: NSManagedObjectContext) throws -> [Vendor] {
    let request: NSFetchRequest<Vendor> = Vendor.fetchRequest()
    request.sortDescriptors = []
    return try context.fetch(request)
}

@Suite(.serialized)
struct VendorDedupTests {
    @Test func normalizationCollapsesWhitespaceAndCase() async throws {
        #expect(" ACME   Parts ".normalizedVendorName == "acme parts")
        #expect("acme parts".normalizedVendorName == "acme parts")
        #expect("ACME PARTS".normalizedVendorName == "acme parts")
        #expect("GLOBAL MOTOR SUPPLY CO. I/ EASTERN REGION".normalizedVendorName == "global motor supply co i eastern region")
        #expect("Mikey-Test, Inc.".normalizedVendorName == "mikey test inc")
    }

    @Test @MainActor func explicitVendorIdSkipsSearchAndCreate() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }

        let api = RecordingShopmonkeyService()
        let submitter = await MainActor.run { POSubmissionService(shopmonkey: api) }

        let payload = POSubmissionPayload(
            vendorId: "v_selected",
            vendorName: "ACME Parts",
            vendorPhone: nil,
            poNumber: nil,
            orderId: "o_1",
            serviceId: "s_1",
            items: [POItem(name: "Brake Pads", quantity: 1, cost: 10)]
        )

        let result = await submitter.submitNew(payload: payload, shouldPersist: false, context: controller.viewContext)
        #expect(result.succeeded == true)
        #expect(api.searchCalls == 0)
        #expect(api.createCalls == 0)
        #expect(api.createPartCalls == 1)
        #expect(api.partVendorIds.first == "v_selected")
    }

    @Test @MainActor func localCacheHitSkipsNetworkSearchAndCreate() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }
        let stores = controller.container.persistentStoreCoordinator.persistentStores
        #expect(stores.count == 1)
        #expect(stores.first?.type == NSInMemoryStoreType)

        let vendor: Vendor = try controller.viewContext.insertObject(Vendor.self)
        vendor.id = "v_cache"
        vendor.name = "ACME Parts"
        vendor.normalizedName = vendor.name.normalizedVendorName
        try controller.viewContext.save()

        let api = RecordingShopmonkeyService()
        let submitter = await MainActor.run { POSubmissionService(shopmonkey: api) }

        let payload = POSubmissionPayload(
            vendorName: " ACME   PARTS ",
            vendorPhone: nil,
            poNumber: nil,
            orderId: "o_1",
            serviceId: "s_1",
            items: [POItem(name: "Brake Pads", quantity: 1, cost: 10)]
        )

        let result = await submitter.submitNew(payload: payload, shouldPersist: false, context: controller.viewContext)
        #expect(result.succeeded == true)
        #expect(api.searchCalls == 0)
        #expect(api.createCalls == 0)
        #expect(api.createPartCalls == 1)
        #expect(api.partVendorIds.first == "v_cache")
    }

    @Test @MainActor func remoteSearchMatchSkipsCreateAndPersistsVendor() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }
        let stores = controller.container.persistentStoreCoordinator.persistentStores
        #expect(stores.count == 1)
        #expect(stores.first?.type == NSInMemoryStoreType)

        let api = RecordingShopmonkeyService()
        api.searchResults = [
            VendorSummary(id: "v_remote", name: "ACME Parts")
        ]

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: api) }

        let payload = POSubmissionPayload(
            vendorName: "acme parts",
            vendorPhone: nil,
            poNumber: nil,
            orderId: "o_1",
            serviceId: "s_1",
            items: [POItem(name: "Oil Filter", quantity: 1, cost: 5.50)]
        )

        let result = await submitter.submitNew(payload: payload, shouldPersist: false, context: controller.viewContext)
        #expect(result.succeeded == true)
        #expect(api.searchCalls == 1)
        #expect(api.createCalls == 0)
        #expect(api.partVendorIds.first == "v_remote")

        let cached = try fetchVendors(in: controller.viewContext)
        #expect(cached.count == 1)
        guard let first = cached.first else { return }
        #expect(first.id == "v_remote")
        #expect(first.normalizedName == "acme parts")
    }

    @Test @MainActor func noSearchMatchReturnsValidationErrorAndSkipsAutoCreate() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }
        let stores = controller.container.persistentStoreCoordinator.persistentStores
        #expect(stores.count == 1)
        #expect(stores.first?.type == NSInMemoryStoreType)

        let api = RecordingShopmonkeyService()
        api.searchResults = [
            VendorSummary(id: "v_other", name: "Different Vendor")
        ]

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: api) }

        let payload = POSubmissionPayload(
            vendorName: " ACME   Parts ",
            vendorPhone: nil,
            poNumber: nil,
            orderId: "o_1",
            serviceId: "s_1",
            items: [POItem(name: "Brake Pads", quantity: 2, cost: 19.99)]
        )

        let result = await submitter.submitNew(payload: payload, shouldPersist: false, context: controller.viewContext)
        #expect(result.succeeded == false)
        #expect(api.searchCalls == 1)
        #expect(api.createCalls == 0)
        #expect(api.createPartCalls == 0)
        #expect(result.message?.contains("Select or create a vendor before submitting.") == true)
        #expect(result.message?.contains("ID: \(DiagnosticCode.submitVendorResolve.rawValue)") == true)

        let cached = try fetchVendors(in: controller.viewContext)
        #expect(cached.isEmpty)
    }

    @Test @MainActor func searchFailureDoesNotAutoCreateVendor() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }
        let stores = controller.container.persistentStoreCoordinator.persistentStores
        #expect(stores.count == 1)
        #expect(stores.first?.type == NSInMemoryStoreType)

        let api = RecordingShopmonkeyService()
        api.searchError = APIError.serverError(500)

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: api) }

        let payload = POSubmissionPayload(
            vendorName: "ACME Parts",
            vendorPhone: nil,
            poNumber: nil,
            orderId: "o_1",
            serviceId: "s_1",
            items: [POItem(name: "Oil Filter", quantity: 1, cost: 1)]
        )

        let result = await submitter.submitNew(payload: payload, shouldPersist: false, context: controller.viewContext)
        #expect(result.succeeded == false)
        #expect(api.searchCalls == 1)
        #expect(api.createCalls == 0)
        #expect(api.createPartCalls == 0)
        #expect(result.message?.contains("Server error (500)") == true)
        #expect(result.message?.contains("ID: \(DiagnosticCode.apiServer5xx.rawValue)") == true)
    }
}
