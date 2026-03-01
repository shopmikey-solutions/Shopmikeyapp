//
//  ReceiveItemViewModel.swift
//  POScannerApp
//

import Combine
import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import ShopmikeyCoreSync

struct PurchaseOrderLineItemReceivePayload: Hashable, Codable, Sendable {
    static let fingerprintPrefix = "purchase_order_receive_v1"

    var purchaseOrderID: String
    var lineItemID: String
    var quantityReceived: Decimal
    var barcode: String
    var sku: String?
    var partNumber: String?
    var description: String?

    var payloadFingerprint: String {
        let pairs: [(String, String)] = [
            ("purchaseOrderId", purchaseOrderID),
            ("lineItemId", lineItemID),
            ("quantityReceived", decimalString(quantityReceived)),
            ("barcode", barcode),
            ("sku", sku ?? ""),
            ("partNumber", partNumber ?? ""),
            ("description", description ?? "")
        ]

        return Self.fingerprintPrefix + "|" + pairs
            .map { key, value in
                "\(key)=\(Self.percentEncode(value))"
            }
            .joined(separator: "|")
    }

    static func from(payloadFingerprint: String) -> PurchaseOrderLineItemReceivePayload? {
        guard payloadFingerprint.hasPrefix(fingerprintPrefix + "|") else {
            return nil
        }

        let rawPairs = payloadFingerprint
            .dropFirst((fingerprintPrefix + "|").count)
            .split(separator: "|")

        var values: [String: String] = [:]
        values.reserveCapacity(rawPairs.count)

        for pair in rawPairs {
            let components = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }
            values[components[0]] = percentDecode(components[1]) ?? ""
        }

        guard let purchaseOrderID = normalized(values["purchaseOrderId"]),
              let lineItemID = normalized(values["lineItemId"]),
              let quantityRaw = normalized(values["quantityReceived"]),
              let quantityReceived = Decimal(string: quantityRaw),
              quantityReceived > .zero else {
            return nil
        }

        return PurchaseOrderLineItemReceivePayload(
            purchaseOrderID: purchaseOrderID,
            lineItemID: lineItemID,
            quantityReceived: quantityReceived,
            barcode: normalized(values["barcode"]) ?? "",
            sku: normalized(values["sku"]),
            partNumber: normalized(values["partNumber"]),
            description: normalized(values["description"])
        )
    }

    private func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "|=&")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func percentDecode(_ value: String) -> String? {
        value.removingPercentEncoding
    }
}

@MainActor
final class ReceiveItemViewModel: ObservableObject {
    enum MatchState: Equatable {
        case idle
        case scanning
        case matched(PurchaseOrderLineItem)
        case noMatch
        case error(String)
    }

    enum ReceiveState: Equatable {
        case idle
        case receiving
        case succeeded
        case queued(diagnosticCode: String?)
        case failed(diagnosticCode: String?)
    }

    @Published private(set) var purchaseOrderDetail: PurchaseOrderDetail?
    @Published private(set) var scannedCode: String?
    @Published private(set) var matchState: MatchState = .idle
    @Published private(set) var receiveState: ReceiveState = .idle
    @Published private(set) var receiveMessage: String?
    @Published private(set) var lastOperationID: UUID?

    let purchaseOrderID: String

    private let shopmonkeyAPI: any ShopmonkeyServicing
    private let purchaseOrderStore: any PurchaseOrderStoring
    private let inventoryStore: any InventoryStoring
    private let syncOperationQueue: SyncOperationQueueStore
    private let syncEngine: SyncEngine
    private let dateProvider: any DateProviding

    init(
        purchaseOrderID: String,
        shopmonkeyAPI: any ShopmonkeyServicing,
        purchaseOrderStore: any PurchaseOrderStoring,
        inventoryStore: any InventoryStoring,
        syncOperationQueue: SyncOperationQueueStore,
        syncEngine: SyncEngine,
        dateProvider: any DateProviding
    ) {
        self.purchaseOrderID = purchaseOrderID
        self.shopmonkeyAPI = shopmonkeyAPI
        self.purchaseOrderStore = purchaseOrderStore
        self.inventoryStore = inventoryStore
        self.syncOperationQueue = syncOperationQueue
        self.syncEngine = syncEngine
        self.dateProvider = dateProvider
    }

    func loadInitialDetail() async {
        if let cached = await purchaseOrderStore.loadPurchaseOrderDetail(id: purchaseOrderID) {
            purchaseOrderDetail = cached
            return
        }

        await refreshPurchaseOrderDetail()
    }

    func refreshPurchaseOrderDetail() async {
        do {
            let fetched = try await shopmonkeyAPI.fetchPurchaseOrder(id: purchaseOrderID)
            await purchaseOrderStore.savePurchaseOrderDetail(fetched)
            purchaseOrderDetail = await purchaseOrderStore.loadPurchaseOrderDetail(id: purchaseOrderID)
            if case .error = matchState {
                matchState = .idle
            }
        } catch {
            matchState = .error("Could not refresh purchase order details.")
        }
    }

    func startScanning() {
        matchState = .scanning
        receiveState = .idle
        receiveMessage = nil
    }

    func setScannerUnavailable() {
        matchState = .error("Scanner unavailable on this device.")
    }

    func lookup(scannedCode rawCode: String?) async {
        let exactCode = Self.trimmed(rawCode)
        scannedCode = exactCode
        receiveState = .idle
        receiveMessage = nil

        guard let exactCode else {
            matchState = .idle
            return
        }

        guard let detail = purchaseOrderDetail else {
            matchState = .error("Purchase order details are unavailable.")
            return
        }

        if let matched = Self.matchingLineItem(for: exactCode, in: detail) {
            matchState = .matched(matched)
            return
        }

        matchState = .noMatch
    }

    func receiveMatchedLine(quantity: Decimal) async {
        guard case .matched(let lineItem) = matchState else {
            receiveState = .failed(diagnosticCode: nil)
            receiveMessage = "Scan a matching line item before receiving."
            return
        }

        let normalizedQuantity = max(quantity, Decimal.zero)
        guard normalizedQuantity > .zero else {
            receiveState = .failed(diagnosticCode: nil)
            receiveMessage = "Enter a quantity greater than 0."
            return
        }

        let lineItemID = Self.trimmed(lineItem.id)
        guard let lineItemID else {
            receiveState = .failed(diagnosticCode: nil)
            receiveMessage = "This line item cannot be received because it is missing an identifier."
            return
        }

        let metadata = await inventoryMetadata(for: scannedCode)
        let payload = PurchaseOrderLineItemReceivePayload(
            purchaseOrderID: purchaseOrderID,
            lineItemID: lineItemID,
            quantityReceived: normalizedQuantity,
            barcode: Self.trimmed(scannedCode) ?? "",
            sku: metadata.sku ?? Self.trimmed(lineItem.sku),
            partNumber: metadata.partNumber ?? Self.trimmed(lineItem.partNumber),
            description: metadata.description ?? Self.trimmed(lineItem.description)
        )

        let operation = SyncOperation(
            id: UUID(),
            type: .receivePurchaseOrderLineItem,
            payloadFingerprint: payload.payloadFingerprint,
            status: .pending,
            retryCount: 0,
            createdAt: dateProvider.now
        )

        receiveState = .receiving
        receiveMessage = nil
        lastOperationID = operation.id

        _ = await syncOperationQueue.enqueue(operation)
        await syncEngine.runOnce()

        guard let persisted = await syncOperationQueue.operation(id: operation.id) else {
            receiveState = .succeeded
            receiveMessage = "Received successfully."
            purchaseOrderDetail = await purchaseOrderStore.loadPurchaseOrderDetail(id: purchaseOrderID)
            return
        }

        switch persisted.status {
        case .pending, .inProgress:
            receiveState = .queued(diagnosticCode: persisted.lastErrorCode)
            receiveMessage = "Receive queued for retry."
        case .failed:
            receiveState = .failed(diagnosticCode: persisted.lastErrorCode)
            if let code = persisted.lastErrorCode {
                receiveMessage = "Could not receive line item. (ID: \(code))"
            } else {
                receiveMessage = "Could not receive line item."
            }
        case .succeeded:
            receiveState = .succeeded
            receiveMessage = "Received successfully."
            await syncOperationQueue.remove(id: operation.id)
            purchaseOrderDetail = await purchaseOrderStore.loadPurchaseOrderDetail(id: purchaseOrderID)
        }
    }

    private func inventoryMetadata(for scannedCode: String?) async -> (sku: String?, partNumber: String?, description: String?) {
        guard let exactCode = Self.trimmed(scannedCode),
              let normalizedCode = Self.normalized(exactCode) else {
            return (nil, nil, nil)
        }

        let items = await inventoryStore.allItems()

        if let skuMatch = items.first(where: { Self.normalized($0.sku) == normalizedCode }) {
            return (Self.trimmed(skuMatch.sku), Self.trimmed(skuMatch.partNumber), Self.trimmed(skuMatch.description))
        }

        if let partMatch = items.first(where: { Self.normalized($0.partNumber) == normalizedCode }) {
            return (Self.trimmed(partMatch.sku), Self.trimmed(partMatch.partNumber), Self.trimmed(partMatch.description))
        }

        if let descriptionMatch = items.first(where: {
            Self.normalized($0.sku) == nil &&
            Self.normalized($0.partNumber) == nil &&
            Self.normalized($0.description) == normalizedCode
        }) {
            return (
                Self.trimmed(descriptionMatch.sku),
                Self.trimmed(descriptionMatch.partNumber),
                Self.trimmed(descriptionMatch.description)
            )
        }

        return (nil, nil, nil)
    }

    private static func matchingLineItem(for scannedCode: String, in detail: PurchaseOrderDetail) -> PurchaseOrderLineItem? {
        guard let normalizedScannedCode = normalized(scannedCode) else { return nil }

        if let skuMatch = detail.lineItems.first(where: { lineItem in
            normalized(lineItem.sku) == normalizedScannedCode
        }) {
            return skuMatch
        }

        if let partMatch = detail.lineItems.first(where: { lineItem in
            normalized(lineItem.partNumber) == normalizedScannedCode
        }) {
            return partMatch
        }

        return detail.lineItems.first { lineItem in
            guard normalized(lineItem.sku) == nil,
                  normalized(lineItem.partNumber) == nil else {
                return false
            }
            return normalized(lineItem.description) == normalizedScannedCode
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = trimmed(value) else { return nil }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
