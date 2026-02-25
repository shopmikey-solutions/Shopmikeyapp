//
//  ShopmonkeyOrderServiceTests.swift
//  POScannerAppTests
//

import Testing
import Foundation
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

private final class RecordingMutationShopmonkeyService: ShopmonkeyServicing {
    private(set) var createdPartRequests: [CreatePartRequest] = []
    private(set) var createdFeeRequests: [CreateFeeRequest] = []
    private(set) var createdTireRequests: [CreateTireRequest] = []

    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        .init(id: "v_1", name: request.name)
    }

    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        _ = orderId
        _ = serviceId
        createdPartRequests.append(request)
        return .init(id: "p_1", name: request.name)
    }

    func createFee(orderId: String, serviceId: String, request: CreateFeeRequest) async throws -> CreatedResourceResponse {
        _ = orderId
        _ = serviceId
        createdFeeRequests.append(request)
        return .init(id: "f_1")
    }

    func createTire(orderId: String, serviceId: String, request: CreateTireRequest) async throws -> CreatedResourceResponse {
        _ = orderId
        _ = serviceId
        createdTireRequests.append(request)
        return .init(id: "t_1")
    }

    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] { [] }
    func fetchOrders() async throws -> [OrderSummary] { [] }
    func fetchServices(orderId: String) async throws -> [ServiceSummary] { [] }
    func searchVendors(name: String) async throws -> [VendorSummary] { [] }
    func testConnection() async throws {}
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

    @Test func orderSummaryDecoderUsesOrderFieldsForDisplayName() throws {
        let payload = """
        {
          "id": "ord_123",
          "number": "1105",
          "coalescedName": "Standard Oil Change Package",
          "generatedCustomerName": "Alex Driver"
        }
        """

        let order = try JSONDecoder().decode(OrderSummary.self, from: Data(payload.utf8))

        #expect(order.id == "ord_123")
        #expect(order.number == "1105")
        #expect(order.orderName == "Standard Oil Change Package")
        #expect(order.customerName == "Alex Driver")
        #expect(order.displayTitle == "Order #1105 • Standard Oil Change Package")
    }

    @Test func orderSummaryDecoderDoesNotBackfillOrderNameFromNestedServiceName() throws {
        let payload = """
        {
          "id": "ord_456",
          "number": "2107",
          "name": null,
          "services": [
            { "id": "svc_1", "name": "Brake Service" }
          ]
        }
        """

        let order = try JSONDecoder().decode(OrderSummary.self, from: Data(payload.utf8))

        #expect(order.id == "ord_456")
        #expect(order.number == "2107")
        #expect(order.orderName == nil)
        #expect(order.displayTitle == "Order #2107")
    }

    @Test func orderRepositoryDelegatesToShopmonkeyService() async throws {
        let stub = StubShopmonkeyService(
            orders: [.init(id: "o_100", number: "100", customerName: "Driver A")],
            servicesByOrderId: ["o_100": [.init(id: "s_100", name: "Brake Service")]]
        )
        let repository = OrderRepository(shopmonkey: stub)

        let orders = try await repository.fetchOrders()
        let services = try await repository.fetchServices(orderID: "o_100")

        #expect(orders.map(\.id) == ["o_100"])
        #expect(services.map(\.id) == ["s_100"])
    }

    @Test func inventorySyncCoordinatorUpdatesCheckpointAndFreshnessState() async {
        let repository = InventoryRepository()
        let coordinator = InventorySyncCoordinator(repository: repository)
        let firstDate = Date(timeIntervalSince1970: 1_733_070_400) // 2024-12-01 00:00:00 UTC
        let secondDate = firstDate.addingTimeInterval(120)

        let initialFreshness = await coordinator.currentFreshnessState()
        #expect(initialFreshness.status == .neverSynced)
        #expect(initialFreshness.failureCount == 0)

        _ = await coordinator.markSyncSucceeded(cursor: "cursor_1", trigger: .foreground, at: firstDate)
        let checkpoint = await coordinator.currentCheckpoint()
        let freshState = await coordinator.currentFreshnessState()

        #expect(checkpoint.cursor == "cursor_1")
        #expect(checkpoint.lastSyncAt == firstDate)
        #expect(checkpoint.lastTrigger == .foreground)
        #expect(freshState.status == .fresh)
        #expect(freshState.failureCount == 0)

        _ = await coordinator.markSyncFailed(trigger: .background, at: secondDate)
        let failedState = await coordinator.currentFreshnessState()
        let checkpointAfterFailure = await coordinator.currentCheckpoint()

        #expect(failedState.status == .stale)
        #expect(failedState.failureCount == 1)
        #expect(checkpointAfterFailure.lastTrigger == .background)
        #expect(checkpointAfterFailure.cursor == "cursor_1")
    }

    @Test func ticketInventoryMutationServiceRoutesByLineItemKind() async throws {
        let service = RecordingMutationShopmonkeyService()
        let mutationService = TicketInventoryMutationService(shopmonkey: service)
        let request = InventoryMutationRequest(
            action: .attachToTicket,
            orderID: "ord_1",
            serviceID: "svc_1",
            vendorID: "vendor_1",
            purchaseOrderID: "po_1",
            items: [
                POItem(description: "Alternator", quantity: 1, unitCost: 250, partNumber: "ALT-1", kind: .part),
                POItem(description: "All Terrain Tire 225/65R17", quantity: 2, unitCost: 160, partNumber: "TIRE-1", kind: .tire),
                POItem(description: "Shop Supplies Fee", quantity: 1, unitCost: 18.5, partNumber: nil, kind: .fee)
            ]
        )

        let result = try await mutationService.execute(request)

        #expect(result.createdPartCount == 1)
        #expect(result.createdTireCount == 1)
        #expect(result.createdFeeCount == 1)
        #expect(service.createdPartRequests.count == 1)
        #expect(service.createdTireRequests.count == 1)
        #expect(service.createdFeeRequests.count == 1)
    }

    @Test func ticketInventoryMutationServiceRejectsMissingContext() async throws {
        let service = RecordingMutationShopmonkeyService()
        let mutationService = TicketInventoryMutationService(shopmonkey: service)
        let request = InventoryMutationRequest(
            action: .attachToTicket,
            orderID: "",
            serviceID: "",
            vendorID: "vendor_1",
            purchaseOrderID: nil,
            items: [POItem(description: "Alternator", quantity: 1, unitCost: 250, partNumber: "ALT-1", kind: .part)]
        )

        await #expect(throws: InventoryMutationError.self) {
            try await mutationService.execute(request)
        }
    }

    @Test func inventoryRepositoryPersistsSyncStateAndCachesAcrossInstances() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inventory_state_\(UUID().uuidString).json")

        let firstRepository = InventoryRepository(fileURL: fileURL)
        let syncDate = Date(timeIntervalSince1970: 1_736_006_400)

        await firstRepository.persistInventorySyncCheckpoint(
            InventorySyncCheckpoint(cursor: "cursor_sync_1", lastSyncAt: syncDate, lastTrigger: .manual)
        )
        await firstRepository.persistInventoryFreshnessState(
            InventoryFreshnessState(status: .fresh, updatedAt: syncDate, failureCount: 0)
        )
        await firstRepository.upsertOrders(
            [
                OrderSummary(id: "ord_1", number: "1001", orderName: "Brake Service", customerName: "Alex"),
                OrderSummary(id: "ord_2", number: "1002", orderName: nil, customerName: "Jamie")
            ],
            at: syncDate
        )
        await firstRepository.upsertServices(
            [ServiceSummary(id: "svc_1", name: "Brake Job")],
            for: "ord_1",
            at: syncDate
        )

        let secondRepository = InventoryRepository(fileURL: fileURL)
        let checkpoint = await secondRepository.inventorySyncCheckpoint()
        let freshness = await secondRepository.inventoryFreshnessState()
        let cachedOrders = await secondRepository.cachedOrders()
        let cachedServices = await secondRepository.cachedServices(orderID: "ord_1")

        #expect(checkpoint.cursor == "cursor_sync_1")
        #expect(checkpoint.lastTrigger == .manual)
        #expect(freshness.status == .fresh)
        #expect(cachedOrders.map(\.id).sorted() == ["ord_1", "ord_2"])
        #expect(cachedServices.map(\.id) == ["svc_1"])
    }

    @Test func inventorySyncScheduledPullCachesOrdersAndMarksFresh() async {
        let repository = InventoryRepository()
        let coordinator = InventorySyncCoordinator(repository: repository)
        let runDate = Date(timeIntervalSince1970: 1_736_100_000)
        var operationInvocationCount = 0

        let result = await coordinator.runScheduledPull(
            trigger: .foreground,
            now: runDate,
            force: false
        ) { checkpoint in
            operationInvocationCount += 1
            #expect(checkpoint.cursor == nil)
            return InventorySyncPullPayload(
                cursor: "cursor_after_pull",
                orders: [
                    OrderSummary(id: "ord_11", number: "1011", orderName: "Tune Up", customerName: "Sam")
                ],
                servicesByOrderID: [
                    "ord_11": [ServiceSummary(id: "svc_11", name: "Spark Plugs")]
                ]
            )
        }

        let checkpoint = await coordinator.currentCheckpoint()
        let freshness = await coordinator.currentFreshnessState()
        let cachedOrders = await repository.cachedOrders()
        let cachedServices = await repository.cachedServices(orderID: "ord_11")

        #expect(operationInvocationCount == 1)
        #expect(result.didRun == true)
        #expect(result.succeeded == true)
        #expect(result.orderCount == 1)
        #expect(result.serviceCount == 1)
        #expect(checkpoint.cursor == "cursor_after_pull")
        #expect(freshness.status == .fresh)
        #expect(cachedOrders.map(\.id) == ["ord_11"])
        #expect(cachedServices.map(\.id) == ["svc_11"])
    }

    @Test func inventorySyncThrottleSkipsForegroundButManualBypasses() async {
        let repository = InventoryRepository()
        let coordinator = InventorySyncCoordinator(
            repository: repository,
            policy: InventorySyncPolicy(
                foregroundMinimumInterval: 300,
                backgroundMinimumInterval: 600,
                manualMinimumInterval: 0,
                staleAfterInterval: 3_600
            )
        )

        let startDate = Date(timeIntervalSince1970: 1_736_200_000)
        var operationInvocationCount = 0

        _ = await coordinator.runScheduledPull(
            trigger: .foreground,
            now: startDate,
            force: false
        ) { _ in
            operationInvocationCount += 1
            return InventorySyncPullPayload(cursor: "cursor_1")
        }

        let throttledResult = await coordinator.runScheduledPull(
            trigger: .foreground,
            now: startDate.addingTimeInterval(30),
            force: false
        ) { _ in
            operationInvocationCount += 1
            return InventorySyncPullPayload(cursor: "cursor_2")
        }

        let manualResult = await coordinator.runScheduledPull(
            trigger: .manual,
            now: startDate.addingTimeInterval(31),
            force: false
        ) { _ in
            operationInvocationCount += 1
            return InventorySyncPullPayload(cursor: "cursor_3")
        }

        #expect(throttledResult.didRun == false)
        #expect(throttledResult.skipReason == .throttled)
        #expect(manualResult.didRun == true)
        #expect(manualResult.succeeded == true)
        #expect(operationInvocationCount == 2)
    }

    @Test func inventorySyncRefreshFreshnessMarksStaleAfterThreshold() async {
        let repository = InventoryRepository()
        let coordinator = InventorySyncCoordinator(
            repository: repository,
            policy: InventorySyncPolicy(
                foregroundMinimumInterval: 120,
                backgroundMinimumInterval: 600,
                manualMinimumInterval: 0,
                staleAfterInterval: 300
            )
        )

        let syncedAt = Date(timeIntervalSince1970: 1_736_300_000)
        _ = await coordinator.markSyncSucceeded(cursor: "cursor_1", trigger: .foreground, at: syncedAt)

        let freshState = await coordinator.refreshFreshness(now: syncedAt.addingTimeInterval(240))
        let staleState = await coordinator.refreshFreshness(now: syncedAt.addingTimeInterval(360))

        #expect(freshState.status == .fresh)
        #expect(staleState.status == .stale)
        #expect(staleState.failureCount == 0)
    }
}
