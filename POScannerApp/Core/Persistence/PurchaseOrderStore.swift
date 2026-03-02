//
//  PurchaseOrderStore.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels

protocol PurchaseOrderStoring: Sendable {
    func saveOpenPurchaseOrders(_ orders: [PurchaseOrderSummary]) async
    @discardableResult
    func saveOpenPurchaseOrdersPage(page: Int, orders: [PurchaseOrderSummary], pageSize: Int, refreshedAt: Date) async -> Bool
    func loadOpenPurchaseOrders() async -> [PurchaseOrderSummary]
    func loadOpenPurchaseOrdersPage(page: Int, pageSize: Int) async -> [PurchaseOrderSummary]
    func openPurchaseOrderCount() async -> Int
    func loadOpenPurchaseOrderSummary(id: String) async -> PurchaseOrderSummary?
    func loadOpenPurchaseOrderDetails() async -> [PurchaseOrderDetail]
    func savePurchaseOrderDetail(_ detail: PurchaseOrderDetail) async
    func applyReceiveResult(_ detail: PurchaseOrderDetail, at date: Date) async
    func loadPurchaseOrderDetail(id: String) async -> PurchaseOrderDetail?
    func lastRefreshedAt() async -> Date?
    func isStale(now: Date, threshold: TimeInterval) async -> Bool
    func clear() async
}

extension PurchaseOrderStoring {
    @discardableResult
    func saveOpenPurchaseOrdersPage(
        page: Int,
        orders: [PurchaseOrderSummary],
        pageSize: Int = 50,
        refreshedAt: Date = Date()
    ) async -> Bool {
        _ = page
        _ = pageSize
        _ = refreshedAt
        await saveOpenPurchaseOrders(orders)
        return true
    }

    func loadOpenPurchaseOrdersPage(page: Int, pageSize: Int = 50) async -> [PurchaseOrderSummary] {
        guard page >= 0, pageSize > 0 else { return [] }
        let summaries = await loadOpenPurchaseOrders()
        let start = page * pageSize
        guard start < summaries.count else { return [] }
        let end = min(summaries.count, start + pageSize)
        return Array(summaries[start..<end])
    }

    func openPurchaseOrderCount() async -> Int {
        await loadOpenPurchaseOrders().count
    }

    func loadOpenPurchaseOrderSummary(id: String) async -> PurchaseOrderSummary? {
        await loadOpenPurchaseOrders().first { $0.id == id }
    }

    func lastRefreshedAt() async -> Date? { nil }

    func isStale(now: Date, threshold: TimeInterval) async -> Bool {
        _ = now
        _ = threshold
        return true
    }
}

actor PurchaseOrderStore: PurchaseOrderStoring {
    static let defaultPageSize = 50
    static let maxCachePurchaseOrders = 300

    private struct PersistedState: Codable {
        var openPurchaseOrders: [PurchaseOrderSummary]
        var detailsByID: [String: PurchaseOrderDetail]
        var lastRefreshedAt: Date?
    }

    private let fileURL: URL?
    private var hasLoadedState = false
    private var openPurchaseOrders: [PurchaseOrderSummary] = []
    private var openPurchaseOrdersByID: [String: PurchaseOrderSummary] = [:]
    private var detailsByID: [String: PurchaseOrderDetail] = [:]
    private var lastRefreshedAtValue: Date?
    private var inFlightPages: Set<Int> = []

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    func saveOpenPurchaseOrders(_ orders: [PurchaseOrderSummary]) async {
        loadStateIfNeeded()
        openPurchaseOrders = orders
            .map(normalize(summary:))
            .filter { !$0.id.isEmpty }
            .sorted(by: Self.sortPurchaseOrderSummaries)
        enforcePurchaseOrderCap()
        rebuildSummaryIndex()
        lastRefreshedAtValue = Date()
        persistStateIfNeeded()
    }

    @discardableResult
    func saveOpenPurchaseOrdersPage(
        page: Int,
        orders: [PurchaseOrderSummary],
        pageSize: Int = PurchaseOrderStore.defaultPageSize,
        refreshedAt: Date = Date()
    ) async -> Bool {
        loadStateIfNeeded()
        guard page >= 0 else { return false }
        guard !inFlightPages.contains(page) else { return false }
        inFlightPages.insert(page)
        defer { inFlightPages.remove(page) }

        let normalizedPageSize = max(1, pageSize)
        let normalizedOrders = orders
            .map(normalize(summary:))
            .filter { !$0.id.isEmpty }

        if normalizedOrders.isEmpty && page == 0 {
            openPurchaseOrders.removeAll(keepingCapacity: false)
            openPurchaseOrdersByID.removeAll(keepingCapacity: false)
            detailsByID.removeAll(keepingCapacity: false)
            lastRefreshedAtValue = refreshedAt
            persistStateIfNeeded()
            return true
        }

        var orderedIDs = openPurchaseOrders.map(\.id)
        let startIndex = page * normalizedPageSize
        if orderedIDs.count < startIndex {
            orderedIDs.append(contentsOf: Array(repeating: "", count: startIndex - orderedIDs.count))
        }

        for (offset, summary) in normalizedOrders.enumerated() {
            let targetIndex = startIndex + offset
            if orderedIDs.count <= targetIndex {
                orderedIDs.append(summary.id)
            } else {
                orderedIDs[targetIndex] = summary.id
            }
            openPurchaseOrdersByID[summary.id] = summary
        }

        orderedIDs = orderedIDs.filter { !$0.isEmpty }
        if page == 0 && normalizedOrders.count < normalizedPageSize {
            orderedIDs = Array(orderedIDs.prefix(normalizedOrders.count))
        }

        if !orderedIDs.isEmpty {
            let keptIDs = Set(orderedIDs)
            openPurchaseOrdersByID = openPurchaseOrdersByID.filter { keptIDs.contains($0.key) }
            detailsByID = detailsByID.filter { keptIDs.contains($0.key) }
            openPurchaseOrders = orderedIDs.compactMap { openPurchaseOrdersByID[$0] }
        }

        openPurchaseOrders.sort(by: Self.sortPurchaseOrderSummaries)
        enforcePurchaseOrderCap()
        rebuildSummaryIndex()
        lastRefreshedAtValue = refreshedAt
        persistStateIfNeeded()
        return true
    }

    func loadOpenPurchaseOrders() async -> [PurchaseOrderSummary] {
        loadStateIfNeeded()
        return openPurchaseOrders
    }

    func loadOpenPurchaseOrdersPage(page: Int, pageSize: Int = PurchaseOrderStore.defaultPageSize) async -> [PurchaseOrderSummary] {
        loadStateIfNeeded()
        guard page >= 0, pageSize > 0 else { return [] }
        let start = page * pageSize
        guard start < openPurchaseOrders.count else { return [] }
        let end = min(openPurchaseOrders.count, start + pageSize)
        return Array(openPurchaseOrders[start..<end])
    }

    func openPurchaseOrderCount() async -> Int {
        loadStateIfNeeded()
        return openPurchaseOrders.count
    }

    func loadOpenPurchaseOrderSummary(id: String) async -> PurchaseOrderSummary? {
        loadStateIfNeeded()
        return openPurchaseOrdersByID[normalizedID(id)]
    }

    func loadOpenPurchaseOrderDetails() async -> [PurchaseOrderDetail] {
        loadStateIfNeeded()
        let openOrderIDs = Set(openPurchaseOrders.map(\.id))
        guard !openOrderIDs.isEmpty else { return [] }

        return openPurchaseOrders.compactMap { summary in
            let key = normalizedID(summary.id)
            guard openOrderIDs.contains(key) else { return nil }
            return detailsByID[key]
        }
    }

    func savePurchaseOrderDetail(_ detail: PurchaseOrderDetail) async {
        loadStateIfNeeded()
        let key = normalizedID(detail.id)
        guard !key.isEmpty else { return }
        detailsByID[key] = normalize(detail: detail)
        persistStateIfNeeded()
    }

    func applyReceiveResult(_ detail: PurchaseOrderDetail, at date: Date) async {
        loadStateIfNeeded()
        let normalizedDetail = normalize(detail: detail)
        let key = normalizedID(normalizedDetail.id)
        guard !key.isEmpty else { return }

        detailsByID[key] = normalizedDetail

        if isOpenStatus(normalizedDetail.status) {
            let summary = PurchaseOrderSummary(
                id: key,
                vendorName: normalizedDetail.vendorName,
                status: normalizedDetail.status,
                createdAt: normalizedDetail.createdAt,
                updatedAt: normalizedDetail.updatedAt ?? date,
                totalLineCount: normalizedDetail.lineItems.count
            )
            openPurchaseOrdersByID[key] = normalize(summary: summary)
        } else {
            openPurchaseOrdersByID.removeValue(forKey: key)
            detailsByID.removeValue(forKey: key)
        }

        openPurchaseOrders = Array(openPurchaseOrdersByID.values).sorted(by: Self.sortPurchaseOrderSummaries)
        enforcePurchaseOrderCap()
        rebuildSummaryIndex()
        persistStateIfNeeded()
    }

    func loadPurchaseOrderDetail(id: String) async -> PurchaseOrderDetail? {
        loadStateIfNeeded()
        return detailsByID[normalizedID(id)]
    }

    func lastRefreshedAt() async -> Date? {
        loadStateIfNeeded()
        return lastRefreshedAtValue
    }

    func isStale(now: Date, threshold: TimeInterval) async -> Bool {
        loadStateIfNeeded()
        guard let lastRefreshedAtValue else { return true }
        return now.timeIntervalSince(lastRefreshedAtValue) > threshold
    }

    func clear() async {
        loadStateIfNeeded()
        openPurchaseOrders.removeAll(keepingCapacity: false)
        openPurchaseOrdersByID.removeAll(keepingCapacity: false)
        detailsByID.removeAll(keepingCapacity: false)
        lastRefreshedAtValue = nil
        inFlightPages.removeAll(keepingCapacity: false)
        persistStateIfNeeded()
    }

    func debugSummaryIndexCount() async -> Int {
        loadStateIfNeeded()
        return openPurchaseOrdersByID.count
    }

    private func loadStateIfNeeded() {
        guard !hasLoadedState else { return }
        hasLoadedState = true

        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }

        openPurchaseOrders = decoded.openPurchaseOrders
            .map(normalize(summary:))
            .filter { !$0.id.isEmpty }
            .sorted(by: Self.sortPurchaseOrderSummaries)
        detailsByID = decoded.detailsByID.reduce(into: [:]) { partialResult, element in
            let key = normalizedID(element.key)
            guard !key.isEmpty else { return }
            partialResult[key] = normalize(detail: element.value)
        }
        lastRefreshedAtValue = decoded.lastRefreshedAt
        enforcePurchaseOrderCap()
        rebuildSummaryIndex()
    }

    private func persistStateIfNeeded() {
        guard let fileURL else { return }

        let state = PersistedState(
            openPurchaseOrders: openPurchaseOrders,
            detailsByID: detailsByID,
            lastRefreshedAt: lastRefreshedAtValue
        )
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Keep cache persistence best-effort.
        }
    }

    private func rebuildSummaryIndex() {
        openPurchaseOrdersByID = Dictionary(uniqueKeysWithValues: openPurchaseOrders.map { ($0.id, $0) })
    }

    private func enforcePurchaseOrderCap() {
        guard openPurchaseOrders.count > Self.maxCachePurchaseOrders else { return }
        openPurchaseOrders = Array(openPurchaseOrders.prefix(Self.maxCachePurchaseOrders))
        let allowedIDs = Set(openPurchaseOrders.map(\.id))
        openPurchaseOrdersByID = openPurchaseOrdersByID.filter { allowedIDs.contains($0.key) }
        detailsByID = detailsByID.filter { allowedIDs.contains($0.key) }
    }

    private func normalize(summary: PurchaseOrderSummary) -> PurchaseOrderSummary {
        PurchaseOrderSummary(
            id: normalizedID(summary.id),
            vendorName: normalizedOptional(summary.vendorName),
            status: normalizedOptional(summary.status),
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            totalLineCount: summary.totalLineCount
        )
    }

    private func normalize(detail: PurchaseOrderDetail) -> PurchaseOrderDetail {
        PurchaseOrderDetail(
            id: normalizedID(detail.id),
            vendorName: normalizedOptional(detail.vendorName),
            status: normalizedOptional(detail.status),
            createdAt: detail.createdAt,
            updatedAt: detail.updatedAt,
            lineItems: detail.lineItems.map(normalize(lineItem:))
        )
    }

    private func normalize(lineItem: PurchaseOrderLineItem) -> PurchaseOrderLineItem {
        PurchaseOrderLineItem(
            id: normalizedID(lineItem.id),
            kind: normalizedOptional(lineItem.kind),
            sku: normalizedOptional(lineItem.sku),
            partNumber: normalizedOptional(lineItem.partNumber),
            description: lineItem.description.trimmingCharacters(in: .whitespacesAndNewlines),
            quantityOrdered: lineItem.quantityOrdered,
            quantityReceived: lineItem.quantityReceived,
            unitCost: lineItem.unitCost,
            extendedCost: lineItem.extendedCost
        )
    }

    private func normalizedID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isOpenStatus(_ status: String?) -> Bool {
        guard let status else { return true }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        let closedStatuses: Set<String> = [
            "closed",
            "complete",
            "completed",
            "received",
            "cancelled",
            "canceled",
            "archived"
        ]
        return !closedStatuses.contains(normalized)
    }

    private static func sortPurchaseOrderSummaries(lhs: PurchaseOrderSummary, rhs: PurchaseOrderSummary) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return (lhs.updatedAt ?? lhs.createdAt ?? .distantPast) > (rhs.updatedAt ?? rhs.createdAt ?? .distantPast)
        }
        if lhs.createdAt != rhs.createdAt {
            return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        }
        if let lhsVendor = lhs.vendorName, let rhsVendor = rhs.vendorName,
           lhsVendor.localizedCaseInsensitiveCompare(rhsVendor) != .orderedSame {
            return lhsVendor.localizedCaseInsensitiveCompare(rhsVendor) == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}
