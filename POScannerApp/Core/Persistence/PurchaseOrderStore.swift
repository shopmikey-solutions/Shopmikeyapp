//
//  PurchaseOrderStore.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels

protocol PurchaseOrderStoring: Sendable {
    func saveOpenPurchaseOrders(_ orders: [PurchaseOrderSummary]) async
    func loadOpenPurchaseOrders() async -> [PurchaseOrderSummary]
    func loadOpenPurchaseOrderDetails() async -> [PurchaseOrderDetail]
    func savePurchaseOrderDetail(_ detail: PurchaseOrderDetail) async
    func applyReceiveResult(_ detail: PurchaseOrderDetail, at date: Date) async
    func loadPurchaseOrderDetail(id: String) async -> PurchaseOrderDetail?
    func clear() async
}

actor PurchaseOrderStore: PurchaseOrderStoring {
    private struct PersistedState: Codable {
        var openPurchaseOrders: [PurchaseOrderSummary]
        var detailsByID: [String: PurchaseOrderDetail]
    }

    private let fileURL: URL?
    private var hasLoadedState = false
    private var openPurchaseOrders: [PurchaseOrderSummary] = []
    private var detailsByID: [String: PurchaseOrderDetail] = [:]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    func saveOpenPurchaseOrders(_ orders: [PurchaseOrderSummary]) async {
        loadStateIfNeeded()
        openPurchaseOrders = orders
            .map(normalize(summary:))
            .filter { !$0.id.isEmpty }
            .sorted(by: Self.sortPurchaseOrderSummaries)
        persistStateIfNeeded()
    }

    func loadOpenPurchaseOrders() async -> [PurchaseOrderSummary] {
        loadStateIfNeeded()
        return openPurchaseOrders
    }

    func loadOpenPurchaseOrderDetails() async -> [PurchaseOrderDetail] {
        loadStateIfNeeded()

        let openOrderIDs = Set(openPurchaseOrders.map { normalizedID($0.id) })
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
            if let existingIndex = openPurchaseOrders.firstIndex(where: { normalizedID($0.id) == key }) {
                openPurchaseOrders[existingIndex] = normalize(summary: summary)
            } else {
                openPurchaseOrders.append(normalize(summary: summary))
            }
            openPurchaseOrders.sort(by: Self.sortPurchaseOrderSummaries)
        } else {
            openPurchaseOrders.removeAll { normalizedID($0.id) == key }
        }

        persistStateIfNeeded()
    }

    func loadPurchaseOrderDetail(id: String) async -> PurchaseOrderDetail? {
        loadStateIfNeeded()
        return detailsByID[normalizedID(id)]
    }

    func clear() async {
        loadStateIfNeeded()
        openPurchaseOrders.removeAll(keepingCapacity: false)
        detailsByID.removeAll(keepingCapacity: false)
        persistStateIfNeeded()
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
    }

    private func persistStateIfNeeded() {
        guard let fileURL else { return }

        let state = PersistedState(
            openPurchaseOrders: openPurchaseOrders,
            detailsByID: detailsByID
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
