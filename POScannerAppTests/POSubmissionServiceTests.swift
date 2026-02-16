//
//  POSubmissionServiceTests.swift
//  POScannerAppTests
//

import CoreData
import Testing
@testable import POScannerApp

private final class MockShopmonkeyService: ShopmonkeyServicing {
    struct CallCounts: Hashable {
        var createVendor: Int = 0
        var createPart: Int = 0
        var createFee: Int = 0
        var createTire: Int = 0
        var createPurchaseOrder: Int = 0
        var getPurchaseOrders: Int = 0
        var fetchOrders: Int = 0
        var fetchServices: Int = 0
        var searchVendors: Int = 0
    }

    var counts = CallCounts()

    var createVendorResult: Result<CreateVendorResponse, Error> = .success(.init(id: "v_1", name: "ACME"))
    var createPartResult: Result<CreatePartResponse, Error> = .success(.init(id: "p_1", name: "Part"))
    var createFeeResult: Result<CreatedResourceResponse, Error> = .success(.init(id: "f_1"))
    var createTireResult: Result<CreatedResourceResponse, Error> = .success(.init(id: "t_1"))
    var createPurchaseOrderResult: Result<CreatePurchaseOrderResponse, Error> = .success(.init(id: "po_1", vendorId: "v_1", status: "received"))
    var getPurchaseOrdersResult: Result<[PurchaseOrderResponse], Error> = .success([])
    var fetchOrdersResult: Result<[OrderSummary], Error> = .success([])
    var fetchServicesResult: Result<[ServiceSummary], Error> = .success([])
    var searchVendorsResult: Result<[VendorSummary], Error> = .success([])
    var capturedPurchaseOrderRequests: [CreatePurchaseOrderRequest] = []

    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        _ = request
        counts.createVendor += 1
        return try createVendorResult.get()
    }

    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        _ = orderId
        _ = serviceId
        _ = request
        counts.createPart += 1
        return try createPartResult.get()
    }

    func createFee(orderId: String, serviceId: String, request: CreateFeeRequest) async throws -> CreatedResourceResponse {
        _ = orderId
        _ = serviceId
        _ = request
        counts.createFee += 1
        return try createFeeResult.get()
    }

    func createTire(orderId: String, serviceId: String, request: CreateTireRequest) async throws -> CreatedResourceResponse {
        _ = orderId
        _ = serviceId
        _ = request
        counts.createTire += 1
        return try createTireResult.get()
    }

    func createPurchaseOrder(_ request: CreatePurchaseOrderRequest) async throws -> CreatePurchaseOrderResponse {
        capturedPurchaseOrderRequests.append(request)
        counts.createPurchaseOrder += 1
        return try createPurchaseOrderResult.get()
    }

    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] {
        counts.getPurchaseOrders += 1
        return try getPurchaseOrdersResult.get()
    }

    func fetchOrders() async throws -> [OrderSummary] {
        counts.fetchOrders += 1
        return try fetchOrdersResult.get()
    }

    func fetchServices(orderId: String) async throws -> [ServiceSummary] {
        _ = orderId
        counts.fetchServices += 1
        return try fetchServicesResult.get()
    }

    func searchVendors(name: String) async throws -> [VendorSummary] {
        _ = name
        counts.searchVendors += 1
        return try searchVendorsResult.get()
    }

    func testConnection() async throws {
        // Settings-only. Submission tests don't exercise it.
    }
}

private func fetchPurchaseOrders(in context: NSManagedObjectContext) throws -> [PurchaseOrder] {
    let request: NSFetchRequest<PurchaseOrder> = PurchaseOrder.fetchRequest()
    request.sortDescriptors = []
    return try context.fetch(request)
}

struct POSubmissionServiceTests {
    @Test @MainActor func invalidPayloadMissingVendorDoesNotCallNetwork() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }
        let stores = controller.container.persistentStoreCoordinator.persistentStores
        #expect(stores.count == 1)
        #expect(stores.first?.type == NSInMemoryStoreType)

        let mock = MockShopmonkeyService()
        let submitter = await MainActor.run { POSubmissionService(shopmonkey: mock) }

        let payload = POSubmissionPayload(
            vendorName: "",
            vendorPhone: nil,
            poNumber: nil,
            orderId: "",
            serviceId: "",
            items: [POItem(name: "Brake Pads", quantity: 1, cost: 10)]
        )

        let result = await submitter.submitNew(payload: payload, shouldPersist: true, context: controller.viewContext)
        #expect(result.succeeded == false)
        #expect(result.message == "Vendor name is required.")

        let counts = mock.counts
        #expect(counts.createVendor == 0)
        #expect(counts.createPart == 0)
        #expect(counts.getPurchaseOrders == 0)

        let saved = try fetchPurchaseOrders(in: controller.viewContext)
        #expect(saved.isEmpty)
    }

    @Test @MainActor func failedSubmissionPersistsFailedStatusAndLastError() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }
        let stores = controller.container.persistentStoreCoordinator.persistentStores
        #expect(stores.count == 1)
        #expect(stores.first?.type == NSInMemoryStoreType)

        let mock = MockShopmonkeyService()
        mock.createVendorResult = .success(.init(id: "v_1", name: "ACME"))
        mock.createPartResult = .failure(APIError.unauthorized)

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: mock) }

        let payload = POSubmissionPayload(
            vendorId: "v_1",
            vendorName: "ACME",
            vendorPhone: nil,
            poNumber: "123",
            orderId: "o_1",
            serviceId: "s_1",
            items: [POItem(name: "Brake Pads", quantity: 2, cost: 19.99)]
        )

        let result = await submitter.submitNew(payload: payload, shouldPersist: true, context: controller.viewContext)
        #expect(result.succeeded == false)
        #expect(result.message == "Unauthorized")
        guard result.succeeded == false else { return }

        let saved = try fetchPurchaseOrders(in: controller.viewContext)
        #expect(saved.count == 1)
        guard let po = saved.first else { return }
        #expect(po.status == "failed")
        #expect(po.lastError == "Unauthorized")
    }

    @Test @MainActor func successfulSubmissionPersistsSubmittedStatus() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }
        let stores = controller.container.persistentStoreCoordinator.persistentStores
        #expect(stores.count == 1)
        #expect(stores.first?.type == NSInMemoryStoreType)

        let mock = MockShopmonkeyService()
        mock.createVendorResult = .success(.init(id: "v_1", name: "ACME"))
        mock.createPartResult = .success(.init(id: "p_1", name: "Part"))
        mock.getPurchaseOrdersResult = .success([])

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: mock) }

        let payload = POSubmissionPayload(
            vendorId: "v_1",
            vendorName: "ACME",
            vendorPhone: "555-1212",
            poNumber: "123",
            orderId: "o_1",
            serviceId: "s_1",
            items: [
                POItem(name: "Brake Pads", quantity: 2, cost: 19.99),
                POItem(name: "Oil Filter", quantity: 1, cost: 5.50)
            ]
        )

        let result = await submitter.submitNew(payload: payload, shouldPersist: true, context: controller.viewContext)
        #expect(result.message == nil)
        #expect(result.succeeded == true)
        guard result.succeeded == true else { return }

        let saved = try fetchPurchaseOrders(in: controller.viewContext)
        #expect(saved.count == 1)
        guard let po = saved.first else { return }
        #expect(po.status == "submitted")
        #expect(po.submittedAt != nil)
        #expect(po.lastError == nil)
        #expect(po.orderId == "o_1")
        #expect(po.serviceId == "s_1")

        let counts = mock.counts
        #expect(counts.createVendor == 0)
        #expect(counts.createPart == 2)
        #expect(counts.getPurchaseOrders == 1)
    }

    @Test @MainActor func submissionWithoutOrderAndServiceSkipsPartCreation() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }

        let mock = MockShopmonkeyService()
        mock.createVendorResult = .success(.init(id: "v_1", name: "ACME"))
        mock.createPartResult = .success(.init(id: "p_1", name: "Part"))
        mock.getPurchaseOrdersResult = .success([])

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: mock) }

        let payload = POSubmissionPayload(
            vendorId: "v_1",
            vendorName: "ACME",
            vendorPhone: nil,
            poNumber: "PO-1",
            orderId: nil,
            serviceId: nil,
            items: [POItem(name: "Brake Pads", quantity: 1, cost: 42.50)]
        )

        let result = await submitter.submitNew(payload: payload, shouldPersist: true, context: controller.viewContext)
        #expect(result.succeeded == true)
        #expect(result.message == nil)

        let counts = mock.counts
        #expect(counts.createVendor == 0)
        #expect(counts.createPart == 0)
        #expect(counts.getPurchaseOrders == 1)
    }

    @Test @MainActor func quickAddCreatesSinglePurchaseOrderWithAllLineItems() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }

        let mock = MockShopmonkeyService()
        mock.createVendorResult = .success(.init(id: "v_1", name: "ACME"))
        mock.createPurchaseOrderResult = .success(.init(id: "po_1", vendorId: "v_1", status: "received"))
        mock.getPurchaseOrdersResult = .success([])

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: mock) }

        let payload = POSubmissionPayload(
            vendorId: "v_1",
            vendorName: "ACME",
            vendorPhone: nil,
            poNumber: "INV-100",
            orderId: nil,
            serviceId: nil,
            items: [
                POItem(name: "Brake Pads", quantity: 2, cost: 19.99),
                POItem(name: "Shop Supplies", quantity: 1, cost: 5.50)
            ]
        )

        let result = await submitter.submitNew(
            payload: payload,
            mode: .quickAddToTicket,
            shouldPersist: true,
            context: controller.viewContext
        )

        #expect(result.succeeded == true)
        #expect(result.message == nil)

        let counts = mock.counts
        #expect(counts.createPurchaseOrder == 1)
        #expect(counts.createPart == 0)
        #expect(counts.createFee == 0)
        #expect(counts.createTire == 0)

        #expect(mock.capturedPurchaseOrderRequests.count == 1)
        guard let request = mock.capturedPurchaseOrderRequests.first else { return }
        #expect(request.lineItems.count == 2)
        #expect(request.parts.count == 1)
        #expect(request.fees.count == 1)
        #expect(request.tires.count == 0)
        #expect(request.lineItems[0].description == "Brake Pads")
        #expect(request.lineItems[1].description == "Shop Supplies")
        #expect(request.fees[0].name == "Shop Supplies")
    }

    @Test @MainActor func quickAddPurchaseOrderPayloadIncludesPartFeeAndTireCollections() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }

        let mock = MockShopmonkeyService()
        mock.createVendorResult = .success(.init(id: "v_1", name: "ACME"))
        mock.createPurchaseOrderResult = .success(.init(id: "po_1", vendorId: "v_1", status: "draft"))
        mock.getPurchaseOrdersResult = .success([])

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: mock) }

        let payload = POSubmissionPayload(
            vendorId: "v_1",
            vendorName: "ACME",
            vendorPhone: nil,
            poNumber: "INV-200",
            orderId: nil,
            serviceId: nil,
            items: [
                POItem(name: "Brake Pads", quantity: 2, cost: 45.00, partNumber: "BP-123"),
                POItem(name: "Shipping Freight", quantity: 1, cost: 20.00),
                POItem(name: "All-Season Tire 225/45R17", quantity: 4, cost: 110.00, partNumber: "T-22545")
            ]
        )

        let result = await submitter.submitNew(
            payload: payload,
            mode: .quickAddToTicket,
            shouldPersist: true,
            context: controller.viewContext
        )

        #expect(result.succeeded == true)
        #expect(mock.capturedPurchaseOrderRequests.count == 1)
        guard let request = mock.capturedPurchaseOrderRequests.first else { return }

        #expect(request.lineItems.count == 3)
        #expect(request.parts.count == 1)
        #expect(request.fees.count == 1)
        #expect(request.tires.count == 1)

        #expect(request.parts[0].name == "Brake Pads")
        #expect(request.parts[0].number == "BP-123")
        #expect(request.parts[0].costCents == 4_500)
        #expect(request.fees[0].name == "Shipping Freight")
        #expect(request.fees[0].amountCents == 2_000)
        #expect(request.tires[0].name == "All-Season Tire 225/45R17")
        #expect(request.tires[0].number == "T-22545")
        #expect(request.tires[0].costCents == 11_000)
    }

    @Test @MainActor func attachModeClassifiesFeeAndTireSeparately() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }

        let mock = MockShopmonkeyService()
        mock.createVendorResult = .success(.init(id: "v_1", name: "ACME"))
        mock.createPartResult = .success(.init(id: "p_1", name: "Part"))
        mock.createFeeResult = .success(.init(id: "f_1"))
        mock.createTireResult = .success(.init(id: "t_1"))
        mock.getPurchaseOrdersResult = .success([])

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: mock) }

        let payload = POSubmissionPayload(
            vendorId: "v_1",
            vendorName: "ACME",
            vendorPhone: nil,
            poNumber: "PO-200",
            orderId: "o_1",
            serviceId: "s_1",
            items: [
                POItem(name: "Brake Pads", quantity: 1, cost: 42.00),
                POItem(name: "Shipping Freight", quantity: 1, cost: 20.00),
                POItem(name: "All-Season Tire 225/45R17", quantity: 2, cost: 110.00)
            ]
        )

        let result = await submitter.submitNew(
            payload: payload,
            mode: .attachToExistingPO,
            shouldPersist: true,
            context: controller.viewContext
        )

        #expect(result.succeeded == true)
        #expect(result.message == nil)

        let counts = mock.counts
        #expect(counts.createPart == 1)
        #expect(counts.createFee == 1)
        #expect(counts.createTire == 1)
        #expect(counts.createPurchaseOrder == 0)
    }

    @Test @MainActor func quickAddUsesExplicitItemKindWhenProvided() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }

        let mock = MockShopmonkeyService()
        mock.createPurchaseOrderResult = .success(.init(id: "po_9", vendorId: "v_1", status: "draft"))
        mock.getPurchaseOrdersResult = .success([])

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: mock) }

        let payload = POSubmissionPayload(
            vendorId: "v_1",
            vendorName: "ACME",
            vendorPhone: nil,
            poNumber: "INV-900",
            orderId: nil,
            serviceId: nil,
            items: [
                POItem(name: "Flat line", quantity: 1, cost: 10.00, kind: .part, kindConfidence: 0.9),
                POItem(name: "Flat line", quantity: 1, cost: 5.00, kind: .fee, kindConfidence: 0.9),
                POItem(name: "Flat line", quantity: 2, cost: 12.00, kind: .tire, kindConfidence: 0.9)
            ]
        )

        let result = await submitter.submitNew(
            payload: payload,
            mode: .quickAddToTicket,
            shouldPersist: false,
            context: controller.viewContext
        )

        #expect(result.succeeded == true)
        #expect(mock.capturedPurchaseOrderRequests.count == 1)
        guard let request = mock.capturedPurchaseOrderRequests.first else { return }
        #expect(request.parts.count == 1)
        #expect(request.fees.count == 1)
        #expect(request.tires.count == 1)
    }

    @Test @MainActor func quickAddMapsUnknownMountAndBalanceLineToFee() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }

        let mock = MockShopmonkeyService()
        mock.createPurchaseOrderResult = .success(.init(id: "po_11", vendorId: "v_1", status: "draft"))
        mock.getPurchaseOrdersResult = .success([])

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: mock) }

        let payload = POSubmissionPayload(
            vendorId: "v_1",
            vendorName: "ACME",
            vendorPhone: nil,
            poNumber: "INV-902",
            orderId: nil,
            serviceId: nil,
            items: [
                POItem(name: "Mount and Balance Service", quantity: 1, cost: 120.00, kind: .unknown, kindConfidence: 0.2)
            ]
        )

        let result = await submitter.submitNew(
            payload: payload,
            mode: .quickAddToTicket,
            shouldPersist: false,
            context: controller.viewContext
        )

        #expect(result.succeeded == true)
        #expect(mock.capturedPurchaseOrderRequests.count == 1)
        guard let request = mock.capturedPurchaseOrderRequests.first else { return }
        #expect(request.parts.count == 0)
        #expect(request.fees.count == 1)
        #expect(request.tires.count == 0)
    }

    @Test @MainActor func unknownItemKindFallsBackToPartSafely() async throws {
        let controller = DataController(inMemory: true)
        await controller.waitUntilLoaded()
        #expect(controller.loadError == nil)
        guard controller.loadError == nil else { return }

        let mock = MockShopmonkeyService()
        mock.createPurchaseOrderResult = .success(.init(id: "po_10", vendorId: "v_1", status: "draft"))
        mock.getPurchaseOrdersResult = .success([])

        let submitter = await MainActor.run { POSubmissionService(shopmonkey: mock) }

        let payload = POSubmissionPayload(
            vendorId: "v_1",
            vendorName: "ACME",
            vendorPhone: nil,
            poNumber: "INV-901",
            orderId: nil,
            serviceId: nil,
            items: [
                POItem(name: "Mystery Component", quantity: 1, cost: 22.00, kind: .unknown, kindConfidence: 0.2)
            ]
        )

        let result = await submitter.submitNew(
            payload: payload,
            mode: .quickAddToTicket,
            shouldPersist: false,
            context: controller.viewContext
        )

        #expect(result.succeeded == true)
        #expect(mock.capturedPurchaseOrderRequests.count == 1)
        guard let request = mock.capturedPurchaseOrderRequests.first else { return }
        #expect(request.parts.count == 1)
        #expect(request.fees.count == 0)
        #expect(request.tires.count == 0)
    }
}
