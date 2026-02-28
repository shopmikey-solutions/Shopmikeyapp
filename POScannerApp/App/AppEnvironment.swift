//
//  AppEnvironment.swift
//  POScannerApp
//

import Foundation
import SwiftUI

private let requireAuthForTokenPreferenceKey = "settings.requireAuthForToken"

protocol DateProviding: Sendable {
    var now: Date { get }
}

struct SystemDateProvider: DateProviding {
    var now: Date { Date() }
}

private extension String {
    var nilIfEmptyValue: String? {
        isEmpty ? nil : self
    }
}

enum InventorySyncTrigger: String, Hashable, Codable {
    case foreground
    case background
    case manual
}

struct InventorySyncCheckpoint: Hashable, Codable {
    var cursor: String?
    var lastSyncAt: Date?
    var lastTrigger: InventorySyncTrigger?

    static let empty = InventorySyncCheckpoint(cursor: nil, lastSyncAt: nil, lastTrigger: nil)
}

enum InventoryFreshnessStatus: String, Hashable, Codable {
    case neverSynced
    case fresh
    case stale
}

struct InventoryFreshnessState: Hashable, Codable {
    var status: InventoryFreshnessStatus
    var updatedAt: Date?
    var failureCount: Int

    static let initial = InventoryFreshnessState(status: .neverSynced, updatedAt: nil, failureCount: 0)
}

struct InventorySyncPolicy: Hashable {
    var foregroundMinimumInterval: TimeInterval
    var backgroundMinimumInterval: TimeInterval
    var manualMinimumInterval: TimeInterval
    var staleAfterInterval: TimeInterval

    static let `default` = InventorySyncPolicy(
        foregroundMinimumInterval: 120,
        backgroundMinimumInterval: 600,
        manualMinimumInterval: 0,
        staleAfterInterval: 3_600
    )
}

enum InventorySyncSkipReason: String, Hashable {
    case throttled
}

struct InventorySyncPullPayload {
    var cursor: String?
    var orders: [OrderSummary]
    var servicesByOrderID: [String: [ServiceSummary]]

    init(
        cursor: String? = nil,
        orders: [OrderSummary] = [],
        servicesByOrderID: [String: [ServiceSummary]] = [:]
    ) {
        self.cursor = cursor
        self.orders = orders
        self.servicesByOrderID = servicesByOrderID
    }
}

struct InventorySyncRunResult: Hashable {
    var trigger: InventorySyncTrigger
    var didRun: Bool
    var succeeded: Bool
    var skipReason: InventorySyncSkipReason?
    var checkpoint: InventorySyncCheckpoint
    var freshness: InventoryFreshnessState
    var orderCount: Int
    var serviceCount: Int
}

struct InventoryMatchCandidate: Hashable {
    var inventoryItemID: String
    var score: Double
    var reason: String
}

enum InventoryMutationAction: String, Hashable, Codable {
    case attachToTicket
    case restock
    case createNew
}

struct InventoryMutationRequest: Hashable {
    var action: InventoryMutationAction
    var orderID: String
    var serviceID: String
    var vendorID: String
    var purchaseOrderID: String?
    var items: [POItem]
}

struct InventoryMutationResult: Hashable {
    var createdPartCount: Int
    var createdTireCount: Int
    var createdFeeCount: Int
}

protocol InventoryRepositorying {
    func inventorySyncCheckpoint() async -> InventorySyncCheckpoint
    func persistInventorySyncCheckpoint(_ checkpoint: InventorySyncCheckpoint) async
    func inventoryFreshnessState() async -> InventoryFreshnessState
    func persistInventoryFreshnessState(_ state: InventoryFreshnessState) async
    func cachedOrders() async -> [OrderSummary]
    func cachedServices(orderID: String) async -> [ServiceSummary]
    func upsertOrders(_ orders: [OrderSummary], at date: Date) async
    func upsertServices(_ services: [ServiceSummary], for orderID: String, at date: Date) async
}

actor InventoryRepository: InventoryRepositorying {
    private struct CachedOrderRecord: Codable, Hashable {
        var id: String
        var number: String?
        var orderName: String?
        var customerName: String?
        var updatedAt: Date

        init(order: OrderSummary, updatedAt: Date) {
            self.id = order.id
            self.number = order.number
            self.orderName = order.orderName
            self.customerName = order.customerName
            self.updatedAt = updatedAt
        }

        var orderSummary: OrderSummary {
            OrderSummary(id: id, number: number, orderName: orderName, customerName: customerName)
        }
    }

    private struct CachedServiceRecord: Codable, Hashable {
        var id: String
        var name: String?
        var updatedAt: Date

        init(service: ServiceSummary, updatedAt: Date) {
            self.id = service.id
            self.name = service.name
            self.updatedAt = updatedAt
        }

        var serviceSummary: ServiceSummary {
            ServiceSummary(id: id, name: name)
        }
    }

    private struct PersistedState: Codable {
        var checkpoint: InventorySyncCheckpoint
        var freshness: InventoryFreshnessState
        var orders: [CachedOrderRecord]
        var servicesByOrderID: [String: [CachedServiceRecord]]
    }

    private let stateFileURL: URL?
    private var hasLoadedState = false
    private var checkpoint: InventorySyncCheckpoint = .empty
    private var freshness: InventoryFreshnessState = .initial
    private var orderCacheByID: [String: CachedOrderRecord] = [:]
    private var servicesCacheByOrderID: [String: [String: CachedServiceRecord]] = [:]

    init(fileURL: URL? = nil) {
        self.stateFileURL = fileURL
    }

    func inventorySyncCheckpoint() async -> InventorySyncCheckpoint {
        loadStateIfNeeded()
        return checkpoint
    }

    func persistInventorySyncCheckpoint(_ checkpoint: InventorySyncCheckpoint) async {
        loadStateIfNeeded()
        self.checkpoint = checkpoint
        persistStateIfNeeded()
    }

    func inventoryFreshnessState() async -> InventoryFreshnessState {
        loadStateIfNeeded()
        return freshness
    }

    func persistInventoryFreshnessState(_ state: InventoryFreshnessState) async {
        loadStateIfNeeded()
        freshness = state
        persistStateIfNeeded()
    }

    func cachedOrders() async -> [OrderSummary] {
        loadStateIfNeeded()
        return orderCacheByID.values
            .sorted(by: { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }
                return lhs.updatedAt > rhs.updatedAt
            })
            .map(\.orderSummary)
    }

    func cachedServices(orderID: String) async -> [ServiceSummary] {
        loadStateIfNeeded()
        let key = orderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let records = servicesCacheByOrderID[key]?.values else { return [] }
        return records
            .sorted(by: { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }
                return lhs.updatedAt > rhs.updatedAt
            })
            .map(\.serviceSummary)
    }

    func upsertOrders(_ orders: [OrderSummary], at date: Date) async {
        loadStateIfNeeded()
        for order in orders {
            let key = order.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            orderCacheByID[key] = CachedOrderRecord(order: order, updatedAt: date)
        }
        persistStateIfNeeded()
    }

    func upsertServices(_ services: [ServiceSummary], for orderID: String, at date: Date) async {
        loadStateIfNeeded()
        let key = orderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        var cachedServices = servicesCacheByOrderID[key] ?? [:]
        for service in services {
            let serviceID = service.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serviceID.isEmpty else { continue }
            cachedServices[serviceID] = CachedServiceRecord(service: service, updatedAt: date)
        }

        servicesCacheByOrderID[key] = cachedServices
        persistStateIfNeeded()
    }

    private func loadStateIfNeeded() {
        guard !hasLoadedState else { return }
        hasLoadedState = true

        guard let stateFileURL,
              let data = try? Data(contentsOf: stateFileURL),
              let persisted = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }

        checkpoint = persisted.checkpoint
        freshness = persisted.freshness
        orderCacheByID = Dictionary(uniqueKeysWithValues: persisted.orders.map { ($0.id, $0) })
        servicesCacheByOrderID = persisted.servicesByOrderID.reduce(into: [:]) { result, entry in
            let records = Dictionary(uniqueKeysWithValues: entry.value.map { ($0.id, $0) })
            result[entry.key] = records
        }
    }

    private func persistStateIfNeeded() {
        guard let stateFileURL else { return }

        let persisted = PersistedState(
            checkpoint: checkpoint,
            freshness: freshness,
            orders: orderCacheByID.values.sorted(by: { $0.id < $1.id }),
            servicesByOrderID: servicesCacheByOrderID.reduce(into: [:]) { result, entry in
                result[entry.key] = entry.value.values.sorted(by: { $0.id < $1.id })
            }
        )

        do {
            let directoryURL = stateFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            // Best-effort cache persistence: skip write failures to avoid blocking app flows.
        }
    }
}

protocol InventorySyncCoordinating {
    func currentCheckpoint() async -> InventorySyncCheckpoint
    func currentFreshnessState() async -> InventoryFreshnessState
    @discardableResult
    func refreshFreshness(now: Date) async -> InventoryFreshnessState
    @discardableResult
    func markSyncSucceeded(cursor: String?, trigger: InventorySyncTrigger, at: Date) async -> InventoryFreshnessState
    @discardableResult
    func markSyncFailed(trigger: InventorySyncTrigger, at: Date) async -> InventoryFreshnessState
    func runScheduledPull(
        trigger: InventorySyncTrigger,
        now: Date,
        force: Bool,
        operation: @MainActor (InventorySyncCheckpoint) async throws -> InventorySyncPullPayload
    ) async -> InventorySyncRunResult
}

actor InventorySyncCoordinator: InventorySyncCoordinating {
    private let repository: any InventoryRepositorying
    private let policy: InventorySyncPolicy

    init(
        repository: any InventoryRepositorying,
        policy: InventorySyncPolicy = .default
    ) {
        self.repository = repository
        self.policy = policy
    }

    func currentCheckpoint() async -> InventorySyncCheckpoint {
        await repository.inventorySyncCheckpoint()
    }

    func currentFreshnessState() async -> InventoryFreshnessState {
        await repository.inventoryFreshnessState()
    }

    @discardableResult
    func refreshFreshness(now: Date) async -> InventoryFreshnessState {
        let checkpoint = await repository.inventorySyncCheckpoint()
        var freshness = await repository.inventoryFreshnessState()

        guard let lastSyncAt = checkpoint.lastSyncAt else {
            return freshness
        }
        guard now.timeIntervalSince(lastSyncAt) >= policy.staleAfterInterval else {
            return freshness
        }

        if freshness.status != .stale {
            freshness.status = .stale
            freshness.updatedAt = now
            await repository.persistInventoryFreshnessState(freshness)
        }
        return freshness
    }

    @discardableResult
    func markSyncSucceeded(cursor: String?, trigger: InventorySyncTrigger, at: Date) async -> InventoryFreshnessState {
        let normalizedCursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyValue
        let existingCheckpoint = await repository.inventorySyncCheckpoint()
        let checkpoint = InventorySyncCheckpoint(
            cursor: normalizedCursor ?? existingCheckpoint.cursor,
            lastSyncAt: at,
            lastTrigger: trigger
        )
        let freshState = InventoryFreshnessState(
            status: .fresh,
            updatedAt: at,
            failureCount: 0
        )
        await repository.persistInventorySyncCheckpoint(checkpoint)
        await repository.persistInventoryFreshnessState(freshState)
        return freshState
    }

    @discardableResult
    func markSyncFailed(trigger: InventorySyncTrigger, at: Date) async -> InventoryFreshnessState {
        var staleState = await repository.inventoryFreshnessState()
        staleState.status = .stale
        staleState.updatedAt = at
        staleState.failureCount += 1

        var checkpoint = await repository.inventorySyncCheckpoint()
        checkpoint.lastTrigger = trigger
        await repository.persistInventorySyncCheckpoint(checkpoint)
        await repository.persistInventoryFreshnessState(staleState)
        return staleState
    }

    func runScheduledPull(
        trigger: InventorySyncTrigger,
        now: Date,
        force: Bool = false,
        operation: @MainActor (InventorySyncCheckpoint) async throws -> InventorySyncPullPayload
    ) async -> InventorySyncRunResult {
        let checkpoint = await repository.inventorySyncCheckpoint()
        let minimumInterval = minimumInterval(for: trigger)

        if !force,
           let lastSyncAt = checkpoint.lastSyncAt,
           now.timeIntervalSince(lastSyncAt) < minimumInterval {
            let freshness = await refreshFreshness(now: now)
            let refreshedCheckpoint = await repository.inventorySyncCheckpoint()
            return InventorySyncRunResult(
                trigger: trigger,
                didRun: false,
                succeeded: false,
                skipReason: .throttled,
                checkpoint: refreshedCheckpoint,
                freshness: freshness,
                orderCount: 0,
                serviceCount: 0
            )
        }

        do {
            let payload = try await operation(checkpoint)
            await repository.upsertOrders(payload.orders, at: now)

            var totalServiceCount = 0
            for (orderID, services) in payload.servicesByOrderID {
                totalServiceCount += services.count
                await repository.upsertServices(services, for: orderID, at: now)
            }

            let freshness = await markSyncSucceeded(
                cursor: payload.cursor ?? checkpoint.cursor,
                trigger: trigger,
                at: now
            )
            let refreshedCheckpoint = await repository.inventorySyncCheckpoint()
            return InventorySyncRunResult(
                trigger: trigger,
                didRun: true,
                succeeded: true,
                skipReason: nil,
                checkpoint: refreshedCheckpoint,
                freshness: freshness,
                orderCount: payload.orders.count,
                serviceCount: totalServiceCount
            )
        } catch {
            let freshness = await markSyncFailed(trigger: trigger, at: now)
            let refreshedCheckpoint = await repository.inventorySyncCheckpoint()
            return InventorySyncRunResult(
                trigger: trigger,
                didRun: true,
                succeeded: false,
                skipReason: nil,
                checkpoint: refreshedCheckpoint,
                freshness: freshness,
                orderCount: 0,
                serviceCount: 0
            )
        }
    }

    private func minimumInterval(for trigger: InventorySyncTrigger) -> TimeInterval {
        switch trigger {
        case .foreground:
            return policy.foregroundMinimumInterval
        case .background:
            return policy.backgroundMinimumInterval
        case .manual:
            return policy.manualMinimumInterval
        }
    }
}

protocol OrderRepositorying {
    func fetchOrders() async throws -> [OrderSummary]
    func fetchServices(orderID: String) async throws -> [ServiceSummary]
}

struct OrderRepository: OrderRepositorying {
    private let shopmonkey: any ShopmonkeyServicing

    init(shopmonkey: any ShopmonkeyServicing) {
        self.shopmonkey = shopmonkey
    }

    func fetchOrders() async throws -> [OrderSummary] {
        try await shopmonkey.fetchOrders()
    }

    func fetchServices(orderID: String) async throws -> [ServiceSummary] {
        try await shopmonkey.fetchServices(orderId: orderID)
    }
}

enum InventoryMutationError: LocalizedError, Equatable {
    case missingOrderOrServiceContext
    case missingVendorID
    case noSubmittableItems

    var errorDescription: String? {
        switch self {
        case .missingOrderOrServiceContext:
            return "Order and service context are required."
        case .missingVendorID:
            return "Vendor ID is required."
        case .noSubmittableItems:
            return "At least one valid line item is required."
        }
    }
}

protocol TicketInventoryMutationServicing {
    func execute(_ request: InventoryMutationRequest) async throws -> InventoryMutationResult
}

struct TicketInventoryMutationService: TicketInventoryMutationServicing {
    private let shopmonkey: any ShopmonkeyServicing

    init(shopmonkey: any ShopmonkeyServicing) {
        self.shopmonkey = shopmonkey
    }

    func execute(_ request: InventoryMutationRequest) async throws -> InventoryMutationResult {
        let orderID = request.orderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceID = request.serviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let vendorID = request.vendorID.trimmingCharacters(in: .whitespacesAndNewlines)
        let purchaseOrderID = request.purchaseOrderID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyValue

        guard !orderID.isEmpty, !serviceID.isEmpty else {
            throw InventoryMutationError.missingOrderOrServiceContext
        }
        guard !vendorID.isEmpty else {
            throw InventoryMutationError.missingVendorID
        }

        let items = request.items.filter { item in
            !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !items.isEmpty else {
            throw InventoryMutationError.noSubmittableItems
        }

        var createdPartCount = 0
        var createdTireCount = 0
        var createdFeeCount = 0

        for item in items {
            let description = item.name.trimmingCharacters(in: .whitespacesAndNewlines)

            switch normalizedItemKind(for: item) {
            case .part:
                let request = CreatePartRequest(
                    name: description,
                    quantity: item.quantityForSubmission,
                    partNumber: item.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                    wholesaleCostCents: item.costCents,
                    vendorId: vendorID,
                    purchaseOrderId: purchaseOrderID
                )
                _ = try await shopmonkey.createPart(orderId: orderID, serviceId: serviceID, request: request)
                createdPartCount += 1

            case .tire:
                let request = CreateTireRequest(
                    description: description,
                    quantity: item.quantityForSubmission,
                    costCents: item.costCents,
                    vendorId: vendorID,
                    purchaseOrderId: purchaseOrderID
                )
                _ = try await shopmonkey.createTire(orderId: orderID, serviceId: serviceID, request: request)
                createdTireCount += 1

            case .fee:
                let request = CreateFeeRequest(
                    description: description,
                    amountCents: max(item.costCents * item.quantityForSubmission, item.costCents),
                    purchaseOrderId: purchaseOrderID
                )
                _ = try await shopmonkey.createFee(orderId: orderID, serviceId: serviceID, request: request)
                createdFeeCount += 1
            case .unknown:
                let request = CreatePartRequest(
                    name: description,
                    quantity: item.quantityForSubmission,
                    partNumber: item.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                    wholesaleCostCents: item.costCents,
                    vendorId: vendorID,
                    purchaseOrderId: purchaseOrderID
                )
                _ = try await shopmonkey.createPart(orderId: orderID, serviceId: serviceID, request: request)
                createdPartCount += 1
            }
        }

        return InventoryMutationResult(
            createdPartCount: createdPartCount,
            createdTireCount: createdTireCount,
            createdFeeCount: createdFeeCount
        )
    }

    private func normalizedItemKind(for item: POItem) -> POItemKind {
        if item.kind != .unknown {
            return item.kind
        }

        let loweredName = item.name.lowercased()
        if loweredName.contains("tire") {
            return .tire
        }
        if loweredName.contains("fee") || loweredName.contains("tax") || loweredName.contains("shipping") {
            return .fee
        }

        return .part
    }
}

/// Lightweight dependency container injected through SwiftUI Environment.
struct AppEnvironment {
    let dataController: DataController
    let keychainService: KeychainService
    let secureStorage: SecureStorage
    let networkDiagnostics: NetworkDiagnosticsRecorder
    let telemetryQueue: TelemetryQueue
    let syncOperationQueue: SyncOperationQueueStore
    let reviewDraftStore: any ReviewDraftStoring
    let localNotificationService: LocalNotificationService
    let apiClient: APIClient
    let shopmonkeyAPI: any ShopmonkeyServicing
    let ocrService: OCRService
    let poParser: POParser
    let foundationModelService: FoundationModelService
    let parseHandoffService: LocalParseHandoffService
    let inventoryRepository: any InventoryRepositorying
    let inventorySyncCoordinator: any InventorySyncCoordinating
    let orderRepository: any OrderRepositorying
    let ticketInventoryMutationService: any TicketInventoryMutationServicing
    let dateProvider: any DateProviding

    init(
        dataController: DataController,
        keychainService: KeychainService,
        secureStorage: SecureStorage,
        networkDiagnostics: NetworkDiagnosticsRecorder,
        telemetryQueue: TelemetryQueue = .shared,
        syncOperationQueue: SyncOperationQueueStore = .shared,
        reviewDraftStore: any ReviewDraftStoring,
        localNotificationService: LocalNotificationService,
        apiClient: APIClient,
        shopmonkeyAPI: any ShopmonkeyServicing,
        ocrService: OCRService,
        poParser: POParser,
        foundationModelService: FoundationModelService,
        parseHandoffService: LocalParseHandoffService,
        inventoryRepository: any InventoryRepositorying,
        inventorySyncCoordinator: any InventorySyncCoordinating,
        orderRepository: any OrderRepositorying,
        ticketInventoryMutationService: any TicketInventoryMutationServicing,
        dateProvider: any DateProviding
    ) {
        self.dataController = dataController
        self.keychainService = keychainService
        self.secureStorage = secureStorage
        self.networkDiagnostics = networkDiagnostics
        self.telemetryQueue = telemetryQueue
        self.syncOperationQueue = syncOperationQueue
        self.reviewDraftStore = reviewDraftStore
        self.localNotificationService = localNotificationService
        self.apiClient = apiClient
        self.shopmonkeyAPI = shopmonkeyAPI
        self.ocrService = ocrService
        self.poParser = poParser
        self.foundationModelService = foundationModelService
        self.parseHandoffService = parseHandoffService
        self.inventoryRepository = inventoryRepository
        self.inventorySyncCoordinator = inventorySyncCoordinator
        self.orderRepository = orderRepository
        self.ticketInventoryMutationService = ticketInventoryMutationService
        self.dateProvider = dateProvider
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    static var defaultValue: AppEnvironment { .preview }
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}

extension AppEnvironment {
    static func live() -> AppEnvironment {
        let dataController = DataController()
        let keychainService = KeychainService()
        let secureStorage = SecureStorage(keychainService: keychainService)
        let networkDiagnostics = NetworkDiagnosticsRecorder.shared
        let telemetryQueue = TelemetryQueue.shared
        let syncOperationQueue = SyncOperationQueueStore(fileURL: syncOperationQueueFileURL())
        let reviewDraftStore = ReviewDraftStore()
        let localNotificationService = LocalNotificationService()

        let apiClient = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            tokenProvider: {
                do {
                    return try keychainService.retrieveToken()
                } catch KeychainService.KeychainServiceError.itemNotFound {
                    throw APIError.missingToken
                } catch {
                    throw error
                }
            },
            diagnosticsRecorder: networkDiagnostics
        )
        let shopmonkeyAPI = ShopmonkeyAPI(client: apiClient, diagnosticsRecorder: networkDiagnostics)
        let inventoryRepository = InventoryRepository(fileURL: inventorySyncStateFileURL())
        let inventorySyncCoordinator = InventorySyncCoordinator(repository: inventoryRepository)
        let orderRepository = OrderRepository(shopmonkey: shopmonkeyAPI)
        let ticketInventoryMutationService = TicketInventoryMutationService(shopmonkey: shopmonkeyAPI)

        return AppEnvironment(
            dataController: dataController,
            keychainService: keychainService,
            secureStorage: secureStorage,
            networkDiagnostics: networkDiagnostics,
            telemetryQueue: telemetryQueue,
            syncOperationQueue: syncOperationQueue,
            reviewDraftStore: reviewDraftStore,
            localNotificationService: localNotificationService,
            apiClient: apiClient,
            shopmonkeyAPI: shopmonkeyAPI,
            ocrService: OCRService(),
            poParser: POParser(),
            foundationModelService: FoundationModelService(),
            parseHandoffService: LocalParseHandoffService(),
            inventoryRepository: inventoryRepository,
            inventorySyncCoordinator: inventorySyncCoordinator,
            orderRepository: orderRepository,
            ticketInventoryMutationService: ticketInventoryMutationService,
            dateProvider: SystemDateProvider()
        )
    }

    private static func inventorySyncStateFileURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("POScannerApp", isDirectory: true)
            .appendingPathComponent("inventory_sync_state.json", isDirectory: false)
    }

    private static func syncOperationQueueFileURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("POScannerApp", isDirectory: true)
            .appendingPathComponent("sync_operation_queue.json", isDirectory: false)
    }

    static var preview: AppEnvironment {
        let dataController = DataController(inMemory: true)
        let keychainService = KeychainService(service: "POScannerApp.preview")
        let secureStorage = SecureStorage(keychainService: keychainService)
        let networkDiagnostics = NetworkDiagnosticsRecorder.shared
        let telemetryQueue = TelemetryQueue(
            defaults: UserDefaults(suiteName: "POScannerApp.preview.telemetry") ?? .standard,
            storageKey: "com.mikey.POScannerApp.preview.telemetry.queue.v1"
        )
        let syncOperationQueue = SyncOperationQueueStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("preview_sync_operation_queue.json", isDirectory: false)
        )
        let reviewDraftStore = ReviewDraftStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview_review_drafts.json"))
        let localNotificationService = LocalNotificationService()

        let apiClient = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            tokenProvider: { throw APIError.missingToken },
            diagnosticsRecorder: networkDiagnostics
        )
        let shopmonkeyAPI = ShopmonkeyAPI(client: apiClient, diagnosticsRecorder: networkDiagnostics)
        let inventoryRepository = InventoryRepository()
        let inventorySyncCoordinator = InventorySyncCoordinator(repository: inventoryRepository)
        let orderRepository = OrderRepository(shopmonkey: shopmonkeyAPI)
        let ticketInventoryMutationService = TicketInventoryMutationService(shopmonkey: shopmonkeyAPI)

        return AppEnvironment(
            dataController: dataController,
            keychainService: keychainService,
            secureStorage: secureStorage,
            networkDiagnostics: networkDiagnostics,
            telemetryQueue: telemetryQueue,
            syncOperationQueue: syncOperationQueue,
            reviewDraftStore: reviewDraftStore,
            localNotificationService: localNotificationService,
            apiClient: apiClient,
            shopmonkeyAPI: shopmonkeyAPI,
            ocrService: OCRService(),
            poParser: POParser(),
            foundationModelService: FoundationModelService(),
            parseHandoffService: LocalParseHandoffService(),
            inventoryRepository: inventoryRepository,
            inventorySyncCoordinator: inventorySyncCoordinator,
            orderRepository: orderRepository,
            ticketInventoryMutationService: ticketInventoryMutationService,
            dateProvider: SystemDateProvider()
        )
    }

    #if DEBUG
    static func test(
        dataController: DataController = DataController(inMemory: true),
        reviewDraftStore: any ReviewDraftStoring = ReviewDraftStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("test_review_drafts.json"))
    ) -> AppEnvironment {
        let keychainService = KeychainService(service: "POScannerApp.test")
        let secureStorage = SecureStorage(keychainService: keychainService)
        let networkDiagnostics = NetworkDiagnosticsRecorder.shared
        let telemetryQueue = TelemetryQueue(
            defaults: UserDefaults(suiteName: "POScannerApp.test.telemetry") ?? .standard,
            storageKey: "com.mikey.POScannerApp.test.telemetry.queue.v1"
        )
        let syncOperationQueue = SyncOperationQueueStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("test_sync_operation_queue.json", isDirectory: false)
        )
        let localNotificationService = LocalNotificationService()

        let apiClient = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            tokenProvider: { throw APIError.missingToken },
            diagnosticsRecorder: networkDiagnostics
        )
        let shopmonkeyAPI = ShopmonkeyAPI(client: apiClient, diagnosticsRecorder: networkDiagnostics)
        let inventoryRepository = InventoryRepository()
        let inventorySyncCoordinator = InventorySyncCoordinator(repository: inventoryRepository)
        let orderRepository = OrderRepository(shopmonkey: shopmonkeyAPI)
        let ticketInventoryMutationService = TicketInventoryMutationService(shopmonkey: shopmonkeyAPI)

        return AppEnvironment(
            dataController: dataController,
            keychainService: keychainService,
            secureStorage: secureStorage,
            networkDiagnostics: networkDiagnostics,
            telemetryQueue: telemetryQueue,
            syncOperationQueue: syncOperationQueue,
            reviewDraftStore: reviewDraftStore,
            localNotificationService: localNotificationService,
            apiClient: apiClient,
            shopmonkeyAPI: shopmonkeyAPI,
            ocrService: OCRService(),
            poParser: POParser(),
            foundationModelService: FoundationModelService(),
            parseHandoffService: LocalParseHandoffService(),
            inventoryRepository: inventoryRepository,
            inventorySyncCoordinator: inventorySyncCoordinator,
            orderRepository: orderRepository,
            ticketInventoryMutationService: ticketInventoryMutationService,
            dateProvider: SystemDateProvider()
        )
    }
    #endif

    func authenticateForSubmissionIfNeeded(forcePrompt: Bool = false) async throws {
        guard UserDefaults.standard.bool(forKey: requireAuthForTokenPreferenceKey) else { return }
        _ = try await secureStorage.retrieveTokenRequiringAuthentication(
            reason: "Authenticate to submit this draft to Shopmonkey.",
            preferCached: !forcePrompt
        )
    }

    func enqueueTelemetryEvent(_ event: TelemetryEvent) async {
        await telemetryQueue.enqueue(event: event)
    }
}
