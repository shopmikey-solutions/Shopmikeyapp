//
//  ReviewViewModelTests.swift
//  POScannerAppTests
//

import Testing
import ShopmikeyCoreParsing
import ShopmikeyCoreModels
import Foundation
import ShopmikeyCoreNetworking
@preconcurrency @testable import POScannerApp

private func makeReviewTestEnvironment(draftFileURL: URL) -> AppEnvironment {
    let dataController = DataController(inMemory: true)
    let keychainService = KeychainService(service: "POScannerApp.tests.\(UUID().uuidString)")
    let secureStorage = SecureStorage(keychainService: keychainService)
    let networkDiagnostics = NetworkDiagnosticsRecorder.shared
    let reviewDraftStore = ReviewDraftStore(fileURL: draftFileURL)
    let localNotificationService = LocalNotificationService()
    let apiClient = APIClient(
        baseURL: ShopmonkeyAPI.baseURL,
        tokenProvider: { throw APIError.missingToken },
        diagnosticsRecorder: networkDiagnostics
    )
    let shopmonkeyAPI = ShopmonkeyAPI(client: apiClient, diagnosticsRecorder: networkDiagnostics)
    let ticketStore = TicketStore()
    let inventoryStore = InventoryStore()
    let inventoryRepository = InventoryRepository()
    let inventorySyncCoordinator = InventorySyncCoordinator(repository: inventoryRepository)
    let orderRepository = OrderRepository(shopmonkey: shopmonkeyAPI)
    let ticketInventoryMutationService = TicketInventoryMutationService(shopmonkey: shopmonkeyAPI)

    return AppEnvironment(
        dataController: dataController,
        keychainService: keychainService,
        secureStorage: secureStorage,
        networkDiagnostics: networkDiagnostics,
        reviewDraftStore: reviewDraftStore,
        localNotificationService: localNotificationService,
        apiClient: apiClient,
        shopmonkeyAPI: shopmonkeyAPI,
        ocrService: OCRService(),
        poParser: POParser(),
        foundationModelService: FoundationModelService(),
        parseHandoffService: LocalParseHandoffService(),
        ticketStore: ticketStore,
        inventoryStore: inventoryStore,
        inventoryRepository: inventoryRepository,
        inventorySyncCoordinator: inventorySyncCoordinator,
        orderRepository: orderRepository,
        ticketInventoryMutationService: ticketInventoryMutationService,
        dateProvider: SystemDateProvider()
    )
}

private func waitForCondition(
    timeout: TimeInterval = 4.0,
    pollInterval: TimeInterval = 0.08,
    condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        let nanos = UInt64((max(0.01, pollInterval) * 1_000_000_000).rounded())
        try? await Task.sleep(nanoseconds: nanos)
    }
    return await condition()
}

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

private final class VendorContactShopmonkeyService: ShopmonkeyServicing, @unchecked Sendable {
    var createVendorRequests: [CreateVendorRequest] = []

    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        createVendorRequests.append(request)
        return .init(id: "v_new", name: request.name)
    }

    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        _ = orderId
        _ = serviceId
        return .init(id: "p_1", name: request.name)
    }

    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] { [] }
    func fetchOrders() async throws -> [OrderSummary] { [] }
    func fetchServices(orderId: String) async throws -> [ServiceSummary] { [] }
    func searchVendors(name: String) async throws -> [VendorSummary] { [] }
    func testConnection() async throws {}
}

private final class VendorLookupCountingService: ShopmonkeyServicing, @unchecked Sendable {
    private(set) var searchCalls: [String] = []
    var cannedVendors: [VendorSummary] = [
        VendorSummary(id: "v_advance", name: "Advance Auto Parts", phone: "555-7000", email: "parts@advance.example")
    ]

    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        .init(id: "v_1", name: request.name)
    }

    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        _ = orderId
        _ = serviceId
        return .init(id: "p_1", name: request.name)
    }

    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] { [] }
    func fetchOrders() async throws -> [OrderSummary] { [] }
    func fetchServices(orderId: String) async throws -> [ServiceSummary] { [] }
    func searchVendors(name: String) async throws -> [VendorSummary] {
        searchCalls.append(name)
        return cannedVendors
    }
    func testConnection() async throws {}
}

@MainActor
struct ReviewViewModelTests {
    @Test func manualTypeOverridePersistsInSubmissionPayload() async throws {
        let parsed = ParsedInvoice(
            vendorName: nil,
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

    @Test func setItemKindTracksOverrideCount() async throws {
        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: nil,
            items: [
                ParsedLineItem(name: "Line A", quantity: 1, costCents: 1000, partNumber: "A-1", confidence: 0.7, kind: .unknown, kindConfidence: 0.4, kindReasons: []),
                ParsedLineItem(name: "Line B", quantity: 1, costCents: 2000, partNumber: "B-1", confidence: 0.7, kind: .part, kindConfidence: 0.9, kindReasons: [])
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: MinimalShopmonkeyService())
        }

        await MainActor.run {
            vm.setItemKind(at: 0, to: .fee)
            vm.setItemKind(at: 0, to: .fee) // no-op second set should not increment again
        }

        let firstKind = await MainActor.run { vm.items[0].kind }
        let overrideCount = await MainActor.run { vm.typeOverrideCount }
        #expect(firstKind == .fee)
        #expect(overrideCount == 1)
    }

    @Test func moveItemsReordersRows() async throws {
        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: nil,
            items: [
                ParsedLineItem(name: "Line A", quantity: 1, costCents: 1000, partNumber: "A-1", confidence: 0.7, kind: .part, kindConfidence: 0.9, kindReasons: []),
                ParsedLineItem(name: "Line B", quantity: 1, costCents: 2000, partNumber: "B-1", confidence: 0.7, kind: .part, kindConfidence: 0.9, kindReasons: []),
                ParsedLineItem(name: "Line C", quantity: 1, costCents: 3000, partNumber: "C-1", confidence: 0.7, kind: .part, kindConfidence: 0.9, kindReasons: [])
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: MinimalShopmonkeyService())
        }

        await MainActor.run {
            vm.moveItems(from: IndexSet(integer: 0), to: 2)
        }

        let descriptions = await MainActor.run { vm.items.map(\.description) }
        #expect(descriptions == ["Line B", "Line A", "Line C"])
    }

    @Test func selectionModelIsDeterministic() async throws {
        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: 6_000,
            items: [
                ParsedLineItem(name: "Line A", quantity: 1, costCents: 1_000, partNumber: "A-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: []),
                ParsedLineItem(name: "Line B", quantity: 1, costCents: 2_000, partNumber: "B-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: []),
                ParsedLineItem(name: "Line C", quantity: 1, costCents: 3_000, partNumber: "C-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: [])
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: MinimalShopmonkeyService())
        }

        let ids = await MainActor.run { vm.items.map(\.id) }
        await MainActor.run {
            vm.toggleSelection(id: ids[0])
        }
        let firstSelection = await MainActor.run { vm.selectedItemIDs }
        let hasSelectionAfterFirstToggle = await MainActor.run { vm.hasSelection }
        #expect(firstSelection == Set([ids[0]]))
        #expect(hasSelectionAfterFirstToggle)

        await MainActor.run {
            vm.toggleSelection(id: ids[0])
        }
        let selectionEmptyAfterSecondToggle = await MainActor.run { vm.selectedItemIDs.isEmpty }
        #expect(selectionEmptyAfterSecondToggle)

        await MainActor.run {
            vm.selectAll()
        }
        let selectAllIDs = await MainActor.run { vm.selectedItemIDs }
        #expect(selectAllIDs.count == 3)
        #expect(selectAllIDs == Set(ids))

        await MainActor.run {
            vm.clearSelection()
        }
        let clearedSelection = await MainActor.run { vm.selectedItemIDs.isEmpty }
        let hasSelectionAfterClear = await MainActor.run { vm.hasSelection }
        #expect(clearedSelection)
        #expect(!hasSelectionAfterClear)
    }

    @Test func bulkSetLineTypeUpdatesOnlySelectedItemsAndPreservesOrder() async throws {
        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: 6_000,
            items: [
                ParsedLineItem(name: "Line A", quantity: 1, costCents: 1_000, partNumber: "A-1", confidence: 0.8, kind: .unknown, kindConfidence: 0.3, kindReasons: []),
                ParsedLineItem(name: "Line B", quantity: 1, costCents: 2_000, partNumber: "B-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: []),
                ParsedLineItem(name: "Line C", quantity: 1, costCents: 3_000, partNumber: "C-1", confidence: 0.8, kind: .tire, kindConfidence: 0.8, kindReasons: [])
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: MinimalShopmonkeyService())
        }

        let ids = await MainActor.run { vm.items.map(\.id) }
        await MainActor.run {
            vm.toggleSelection(id: ids[0])
            vm.toggleSelection(id: ids[2])
            vm.bulkSetLineType(.fee)
        }

        let resultingKinds = await MainActor.run { vm.items.map(\.kind) }
        let descriptions = await MainActor.run { vm.items.map(\.description) }
        let selectionCleared = await MainActor.run { vm.selectedItemIDs.isEmpty }
        #expect(resultingKinds == [.fee, .part, .fee])
        #expect(descriptions == ["Line A", "Line B", "Line C"])
        #expect(selectionCleared)
    }

    @Test func bulkSetUnitCostUpdatesOnlySelectedItems() async throws {
        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: 6_000,
            items: [
                ParsedLineItem(name: "Line A", quantity: 1, costCents: 1_000, partNumber: "A-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: []),
                ParsedLineItem(name: "Line B", quantity: 1, costCents: 2_000, partNumber: "B-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: []),
                ParsedLineItem(name: "Line C", quantity: 1, costCents: 3_000, partNumber: "C-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: [])
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: MinimalShopmonkeyService())
        }

        let ids = await MainActor.run { vm.items.map(\.id) }
        let overrideCost = Decimal(string: "12.34")!
        await MainActor.run {
            vm.toggleSelection(id: ids[0])
            vm.toggleSelection(id: ids[2])
            vm.bulkSetUnitCost(overrideCost)
        }

        let costs = await MainActor.run { vm.items.map(\.unitCost) }
        let selectionCleared = await MainActor.run { vm.selectedItemIDs.isEmpty }
        #expect(costs[0] == overrideCost)
        #expect(costs[1] == Decimal(string: "20")!)
        #expect(costs[2] == overrideCost)
        #expect(selectionCleared)
    }

    @Test func bulkDeleteSelectedRemovesRowsAndPreservesRemainingOrder() async throws {
        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: 10_000,
            items: [
                ParsedLineItem(name: "Line A", quantity: 1, costCents: 1_000, partNumber: "A-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: []),
                ParsedLineItem(name: "Line B", quantity: 1, costCents: 2_000, partNumber: "B-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: []),
                ParsedLineItem(name: "Line C", quantity: 1, costCents: 3_000, partNumber: "C-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: []),
                ParsedLineItem(name: "Line D", quantity: 1, costCents: 4_000, partNumber: "D-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: [])
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: MinimalShopmonkeyService())
        }

        let ids = await MainActor.run { vm.items.map(\.id) }
        await MainActor.run {
            vm.toggleSelection(id: ids[1])
            vm.toggleSelection(id: ids[3])
            vm.bulkDeleteSelected()
        }

        let remainingDescriptions = await MainActor.run { vm.items.map(\.description) }
        let selectionCleared = await MainActor.run { vm.selectedItemIDs.isEmpty }
        #expect(remainingDescriptions == ["Line A", "Line C"])
        #expect(selectionCleared)
    }

    @Test func bulkApplyTriggersAutosaveAndNoOpRepeatPreservesDraftFingerprint() async throws {
        let draftURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-bulk-autosave-\(UUID().uuidString).json")
        let environment = makeReviewTestEnvironment(draftFileURL: draftURL)

        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: 3_000,
            items: [
                ParsedLineItem(name: "Line A", quantity: 1, costCents: 1_000, partNumber: "A-1", confidence: 0.8, kind: .unknown, kindConfidence: 0.3, kindReasons: []),
                ParsedLineItem(name: "Line B", quantity: 1, costCents: 2_000, partNumber: "B-1", confidence: 0.8, kind: .part, kindConfidence: 0.8, kindReasons: [])
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(
                environment: environment,
                parsedInvoice: parsed,
                shopmonkeyService: MinimalShopmonkeyService()
            )
        }

        let firstItemID = await MainActor.run { vm.items[0].id }
        await MainActor.run {
            vm.toggleSelection(id: firstItemID)
            vm.bulkSetLineType(.fee)
        }

        let didPersist = await waitForCondition {
            let drafts = await environment.reviewDraftStore.list()
            return drafts.first?.state.items.first?.kind == .fee
        }
        #expect(didPersist)

        let firstSnapshot = await environment.reviewDraftStore.list().first
        #expect(firstSnapshot?.workflowState == .reviewEdited)
        let initialUpdatedAt = firstSnapshot?.updatedAt

        await MainActor.run {
            vm.toggleSelection(id: firstItemID)
            vm.bulkSetLineType(.fee)
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let secondSnapshot = await environment.reviewDraftStore.list().first
        #expect(secondSnapshot?.updatedAt == initialUpdatedAt)

        try? FileManager.default.removeItem(at: draftURL)
    }

    @Test func selectVendorSuggestionPopulatesVendorContactDetails() async throws {
        let vm = await MainActor.run {
            ReviewViewModel(
                environment: .preview,
                parsedInvoice: ParsedInvoice(items: []),
                shopmonkeyService: MinimalShopmonkeyService()
            )
        }

        await MainActor.run {
            vm.selectVendorSuggestion(
                VendorSummary(
                    id: "v_123",
                    name: "ACME Parts",
                    phone: "555-1212",
                    email: "parts@acme.example",
                    notes: "Ask for parts desk."
                )
            )
        }

        let selectedVendor = await MainActor.run { vm.selectedVendorId }
        let vendorPhone = await MainActor.run { vm.vendorPhone }
        let vendorEmail = await MainActor.run { vm.vendorEmail }
        let vendorNotes = await MainActor.run { vm.vendorNotes }

        #expect(selectedVendor == "v_123")
        #expect(vendorPhone == "555-1212")
        #expect(vendorEmail == "parts@acme.example")
        #expect(vendorNotes == "Ask for parts desk.")
    }

    @Test func createVendorUsesContactFieldsAndSelectsCreatedVendor() async throws {
        let service = VendorContactShopmonkeyService()
        let vm = await MainActor.run {
            ReviewViewModel(
                environment: .preview,
                parsedInvoice: ParsedInvoice(items: []),
                shopmonkeyService: service
            )
        }

        await MainActor.run {
            vm.setVendorName("Brand New Vendor")
            vm.vendorPhone = "800-555-9999"
            vm.vendorEmail = "contact@vendor.example"
            vm.vendorNotes = "Preferred for emergency tire orders."
        }

        await vm.createVendorFromCurrentInput()

        let selectedVendor = await MainActor.run { vm.selectedVendorId }
        let vendorName = await MainActor.run { vm.vendorName }
        let statusMessage = await MainActor.run { vm.statusMessage }

        #expect(service.createVendorRequests.count == 1)
        #expect(service.createVendorRequests.first?.name == "Brand New Vendor")
        #expect(service.createVendorRequests.first?.phone == "800-555-9999")
        #expect(service.createVendorRequests.first?.email == "contact@vendor.example")
        #expect(service.createVendorRequests.first?.notes == "Preferred for emergency tire orders.")
        #expect(selectedVendor == "v_new")
        #expect(vendorName == "Brand New Vendor")
        #expect(statusMessage == "Vendor created and selected.")
    }

    @Test func initializesVendorContactFieldsFromParsedHeader() async throws {
        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: "PO-555",
            invoiceNumber: "INV-555",
            totalCents: 4_500,
            items: [
                ParsedLineItem(
                    name: "Test item",
                    quantity: 1,
                    costCents: 4500,
                    partNumber: "T-1",
                    confidence: 0.8,
                    kind: .part,
                    kindConfidence: 0.75,
                    kindReasons: []
                )
            ],
            header: POHeaderFields(
                vendorName: "ACME Parts",
                vendorPhone: "877-222-9999",
                vendorEmail: "parts@acme.example",
                vendorInvoiceNumber: "INV-555",
                poReference: "PO-555",
                workOrderId: "",
                serviceId: "",
                terms: "",
                notes: ""
            )
        )

        let vm = await MainActor.run {
            ReviewViewModel(environment: .preview, parsedInvoice: parsed, shopmonkeyService: MinimalShopmonkeyService())
        }

        let phone = await MainActor.run { vm.vendorPhone }
        let email = await MainActor.run { vm.vendorEmail }
        #expect(phone == "877-222-9999")
        #expect(email == "parts@acme.example")
    }

    @Test func vendorLookupDebouncesAndReducesPrefixChurn() async throws {
        let service = VendorLookupCountingService()
        let uniqueSeed = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)
        let baseQuery = "Advance \(uniqueSeed)"
        let vm = await MainActor.run {
            ReviewViewModel(
                environment: .preview,
                parsedInvoice: ParsedInvoice(items: []),
                shopmonkeyService: service
            )
        }

        await MainActor.run {
            vm.setVendorName("Ac")
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(service.searchCalls.isEmpty)

        await MainActor.run {
            vm.setVendorName(String(baseQuery))
        }
        try? await Task.sleep(nanoseconds: 650_000_000)
        #expect(service.searchCalls.count == 1)

        await MainActor.run {
            vm.setVendorName("\(baseQuery) Auto")
        }
        try? await Task.sleep(nanoseconds: 650_000_000)
        #expect(service.searchCalls.count == 1)
    }

    @Test func restoredDraftPreservesManualLineTypeOverrides() async throws {
        let parsed = ParsedInvoice(
            vendorName: "Advance Auto Parts - Online Cart",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: 21_995,
            items: [
                ParsedLineItem(
                    name: "AGM Battery H7 850CCA DieHard Gold",
                    quantity: 1,
                    costCents: 21_995,
                    partNumber: "BAT-H7-AGM",
                    confidence: 0.8,
                    kind: .unknown,
                    kindConfidence: 0.4,
                    kindReasons: ["line type confidence below threshold"]
                )
            ]
        )

        let editedItem = POItem(
            description: "AGM Battery H7 850CCA DieHard Gold",
            sku: "BAT-H7-AGM",
            quantity: 1,
            unitCost: Decimal(21995) / 100,
            partNumber: "BAT-H7-AGM",
            confidence: 0.8,
            kind: .part,
            kindConfidence: 0.92,
            kindReasons: ["manual override"]
        )

        let draft = ReviewDraftSnapshot(
            id: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            state: ReviewDraftSnapshot.State(
                parsedInvoice: .init(invoice: parsed),
                vendorName: "Advance Auto Parts - Online Cart",
                vendorPhone: "",
                vendorEmail: nil,
                vendorNotes: nil,
                vendorInvoiceNumber: "",
                poReference: "",
                notes: "",
                selectedVendorId: "v_advance",
                orderId: "",
                serviceId: "",
                items: [editedItem],
                modeUIRawValue: ReviewViewModel.ModeUI.attach.rawValue,
                ignoreTaxOverride: false,
                selectedPOId: nil,
                selectedTicketId: nil,
                workflowStateRawValue: ReviewDraftSnapshot.WorkflowState.reviewEdited.rawValue,
                workflowDetail: "Manual edits saved."
            )
        )

        let vm = await MainActor.run {
            ReviewViewModel(
                environment: .preview,
                parsedInvoice: parsed,
                shopmonkeyService: MinimalShopmonkeyService(),
                draftSnapshot: draft
            )
        }

        try? await Task.sleep(nanoseconds: 450_000_000)
        let restoredKind = await MainActor.run { vm.items.first?.kind }
        #expect(restoredKind == .part)
    }

    @Test func autosavePersistsUpdatedLineItemDetails() async throws {
        let draftURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-autosave-\(UUID().uuidString).json")
        let environment = makeReviewTestEnvironment(draftFileURL: draftURL)

        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: 1_000,
            items: [
                ParsedLineItem(
                    name: "Brake Pad",
                    quantity: 1,
                    costCents: 1_000,
                    partNumber: "BP-1",
                    confidence: 0.9,
                    kind: .part,
                    kindConfidence: 0.9,
                    kindReasons: []
                )
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(
                environment: environment,
                parsedInvoice: parsed,
                shopmonkeyService: MinimalShopmonkeyService()
            )
        }

        await MainActor.run {
            vm.items[0].description = "Brake Pad - Updated"
        }

        let didPersist = await waitForCondition {
            let drafts = await environment.reviewDraftStore.list()
            return drafts.first?.state.items.first?.description == "Brake Pad - Updated"
        }
        #expect(didPersist)
        let savedDescription = await environment.reviewDraftStore.list().first?.state.items.first?.description
        #expect(savedDescription == "Brake Pad - Updated")

        try? FileManager.default.removeItem(at: draftURL)
    }

    @Test func moveItemsAutosavePersistsReorderWorkflowDetail() async throws {
        let draftURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-reorder-\(UUID().uuidString).json")
        let environment = makeReviewTestEnvironment(draftFileURL: draftURL)

        let parsed = ParsedInvoice(
            vendorName: "ACME Parts",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: 6_000,
            items: [
                ParsedLineItem(name: "Line A", quantity: 1, costCents: 1_000, partNumber: "A-1", confidence: 0.7, kind: .part, kindConfidence: 0.9, kindReasons: []),
                ParsedLineItem(name: "Line B", quantity: 1, costCents: 2_000, partNumber: "B-1", confidence: 0.7, kind: .part, kindConfidence: 0.9, kindReasons: []),
                ParsedLineItem(name: "Line C", quantity: 1, costCents: 3_000, partNumber: "C-1", confidence: 0.7, kind: .part, kindConfidence: 0.9, kindReasons: [])
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(
                environment: environment,
                parsedInvoice: parsed,
                shopmonkeyService: MinimalShopmonkeyService()
            )
        }

        await MainActor.run {
            vm.moveItems(from: IndexSet(integer: 0), to: 2)
        }

        let didPersist = await waitForCondition {
            let drafts = await environment.reviewDraftStore.list()
            let workflowDetail = drafts.first?.state.workflowDetail?.lowercased()
            return workflowDetail?.contains("reorder") == true
        }
        #expect(didPersist)
        let workflowDetail = await environment.reviewDraftStore.list().first?.state.workflowDetail
        #expect(workflowDetail?.lowercased().contains("reorder") == true)

        try? FileManager.default.removeItem(at: draftURL)
    }

    @Test func applySuggestedVendorNamePersistsSuggestionWorkflowDetail() async throws {
        let draftURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-suggestion-\(UUID().uuidString).json")
        let environment = makeReviewTestEnvironment(draftFileURL: draftURL)

        let parsed = ParsedInvoice(
            vendorName: "Tire center \(UUID().uuidString.prefix(8))",
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: 1_000,
            items: [
                ParsedLineItem(
                    name: "Shop fee",
                    quantity: 1,
                    costCents: 1_000,
                    partNumber: nil,
                    confidence: 0.8,
                    kind: .fee,
                    kindConfidence: 0.85,
                    kindReasons: []
                )
            ]
        )

        let vm = await MainActor.run {
            ReviewViewModel(
                environment: environment,
                parsedInvoice: parsed,
                shopmonkeyService: MinimalShopmonkeyService()
            )
        }

        await MainActor.run {
            vm.applySuggestedVendorName()
        }

        let didPersist = await waitForCondition {
            let drafts = await environment.reviewDraftStore.list()
            let workflowDetail = drafts.first?.state.workflowDetail
            return workflowDetail == "Vendor suggestion applied."
                || workflowDetail == "Line-item suggestions reviewed."
        }
        #expect(didPersist)
        let workflowDetail = await environment.reviewDraftStore.list().first?.state.workflowDetail
        #expect(
            workflowDetail == "Vendor suggestion applied."
                || workflowDetail == "Line-item suggestions reviewed."
        )

        try? FileManager.default.removeItem(at: draftURL)
    }
}
