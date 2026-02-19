//
//  POSubmissionService.swift
//  POScannerApp
//

import CoreData
import Foundation

enum ValidationError: Error {
    case invalidPayload(String)
    case invalidVendor
    case noSubmittableItems
}

/// Shared submission pipeline used by Review and History retry.
@MainActor
final class POSubmissionService {
    enum LineItemType: String, Hashable {
        case part
        case tire
        case fee
    }

    struct Result: Hashable {
        var succeeded: Bool
        var message: String?
        var purchaseOrderObjectID: NSManagedObjectID?
    }

    private struct SubmissionArtifacts {
        var createdPurchaseOrderID: String?
        var createdPurchaseOrderNumber: String?

        static let empty = SubmissionArtifacts(createdPurchaseOrderID: nil, createdPurchaseOrderNumber: nil)
    }

    private let shopmonkey: ShopmonkeyServicing

    init(shopmonkey: ShopmonkeyServicing) {
        self.shopmonkey = shopmonkey
    }

    func submitNew(
        payload: POSubmissionPayload,
        mode: SubmissionMode? = nil,
        shouldPersist: Bool,
        context: NSManagedObjectContext,
        ignoreTaxAndTotals: Bool = false
    ) async -> Result {
        await submit(
            payload: payload,
            mode: mode,
            purchaseOrder: nil,
            shouldPersist: shouldPersist,
            context: context,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
    }

    func retry(purchaseOrder: PurchaseOrder, ignoreTaxAndTotals: Bool = false) async -> Result {
        guard let context = purchaseOrder.managedObjectContext else {
            return Result(succeeded: false, message: "Unexpected error", purchaseOrderObjectID: nil)
        }

        let payload = POSubmissionPayload(
            vendorName: purchaseOrder.vendorName,
            vendorPhone: nil,
            notes: nil,
            poNumber: purchaseOrder.poNumber,
            orderId: purchaseOrder.orderId,
            serviceId: purchaseOrder.serviceId,
            items: purchaseOrder.itemsSorted.map { managed in
                POItem(
                    id: managed.id,
                    name: managed.name,
                    quantity: Int(managed.quantity),
                    cost: managed.cost,
                    partNumber: nil
                )
            }
        )

        return await submit(
            payload: payload,
            mode: nil,
            purchaseOrder: purchaseOrder,
            shouldPersist: true,
            context: context,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
    }

    // MARK: - Internals

    private func submit(
        payload: POSubmissionPayload,
        mode: SubmissionMode?,
        purchaseOrder: PurchaseOrder?,
        shouldPersist: Bool,
        context: NSManagedObjectContext,
        ignoreTaxAndTotals: Bool
    ) async -> Result {
        let submissionStart = Date()

        do {
            // Stage 1: Validation
            try stage1Validate(payload)
        } catch {
            let message = userMessage(for: error)
            stage4PersistFinalStatus(purchaseOrder: purchaseOrder, status: "failed", message: message, context: context)
            return Result(succeeded: false, message: message, purchaseOrderObjectID: purchaseOrder?.objectID)
        }

        // Persist locally first (optional).
        let poRecord: PurchaseOrder?
        do {
            poRecord = try persistSubmittingRecord(
                payload: payload,
                purchaseOrder: purchaseOrder,
                shouldPersist: shouldPersist,
                context: context
            )
        } catch {
            let message = userMessage(for: error)
            stage4PersistFinalStatus(purchaseOrder: purchaseOrder, status: "failed", message: message, context: context)
            return Result(succeeded: false, message: message, purchaseOrderObjectID: purchaseOrder?.objectID)
        }

        do {
            // Stage 2: Vendor resolution
            let vendorId = try await stage2ResolveVendorId(payload: payload, context: context)

            // Stage 3: Mode-aware line item submission
            let submissionArtifacts = try await stage3SubmitLineItems(
                payload: payload,
                vendorId: vendorId,
                mode: mode,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )

            // Best-effort verify. A failure here should not block a successful submission.
            let knownPurchaseOrders = await bestEffortFetchPurchaseOrders()
            let submittedPONumber = resolveSubmittedPONumber(
                from: submissionArtifacts,
                knownPurchaseOrders: knownPurchaseOrders
            )

            // Stage 4: Persist final status
            stage4PersistFinalStatus(
                purchaseOrder: poRecord,
                status: "submitted",
                message: nil,
                submittedPONumber: submittedPONumber,
                context: context
            )
            return Result(succeeded: true, message: nil, purchaseOrderObjectID: poRecord?.objectID)
        } catch {
            let message = await detailedUserMessage(for: error, since: submissionStart)
            stage4PersistFinalStatus(purchaseOrder: poRecord, status: "failed", message: message, context: context)
            return Result(succeeded: false, message: message, purchaseOrderObjectID: poRecord?.objectID)
        }
    }

    // MARK: - Stage 1: Validation

    private func stage1Validate(_ payload: POSubmissionPayload) throws {
        if let message = payload.validationMessage {
            throw ValidationError.invalidPayload(message)
        }

        // Guard: vendor name should not resemble a product/line item.
        let upperVendor = payload.vendorName.uppercased()
        if upperVendor.contains("BRAKE") || upperVendor.contains("OIL") {
            throw ValidationError.invalidVendor
        }
    }

    // MARK: - Local Persistence (Submitting)

    private func persistSubmittingRecord(
        payload: POSubmissionPayload,
        purchaseOrder: PurchaseOrder?,
        shouldPersist: Bool,
        context: NSManagedObjectContext
    ) throws -> PurchaseOrder? {
        let poRecord: PurchaseOrder?

        if let purchaseOrder {
            poRecord = purchaseOrder
        } else if shouldPersist {
            poRecord = try context.insertObject(PurchaseOrder.self)
        } else {
            poRecord = nil
        }

        guard let poRecord else {
            return nil
        }

        let now = Date()
        poRecord.vendorName = payload.vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        poRecord.poNumber =
            payload.poReference?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? payload.poNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? payload.invoiceNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        poRecord.orderId = payload.orderId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        poRecord.serviceId = payload.serviceId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        poRecord.date = now
        poRecord.status = "submitting"
        poRecord.submittedAt = nil
        poRecord.lastError = nil
        poRecord.totalAmount = payload.items.reduce(0) { $0 + (Double($1.quantity) * $1.cost) }

        if purchaseOrder == nil {
            let managedItems: [Item] = try payload.items.map { poItem in
                let item: Item = try context.insertObject(Item.self)
                item.name = poItem.name.trimmingCharacters(in: .whitespacesAndNewlines)
                item.quantity = Int16(clamping: poItem.quantityForSubmission)
                item.cost = poItem.cost
                item.purchaseOrder = poRecord
                return item
            }
            poRecord.items = Set(managedItems)
        }

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                #if DEBUG
                let nsError = error as NSError
                print("Core Data save failed: \(nsError.domain) (\(nsError.code))")
                #endif
                throw error
            }
        }

        return poRecord
    }

    // MARK: - Stage 2: Vendor resolution (de-dup)

    private func stage2ResolveVendorId(payload: POSubmissionPayload, context: NSManagedObjectContext) async throws -> String {
        let normalized = payload.vendorName.normalizedVendorName

        if let selectedVendorID = payload.vendorId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            persistVendor(
                VendorSummary(
                    id: selectedVendorID,
                    name: payload.vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                context: context
            )
            return selectedVendorID
        }

        // Guard: vendor resolution should never proceed with a line item string.
        let upperVendor = payload.vendorName.uppercased()
        guard !upperVendor.contains("BRAKE"), !upperVendor.contains("OIL") else {
            throw ValidationError.invalidVendor
        }

        if let cached = fetchCachedVendor(normalizedName: normalized, context: context) {
            let cachedId = cached.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cachedId.isEmpty {
                return cachedId
            }
        }

        let results = try await shopmonkey.searchVendors(name: normalized)
        if let match = bestVendorMatch(in: results, normalizedQuery: normalized) {
            persistVendor(match, context: context)
            return match.id
        }

        throw ValidationError.invalidPayload("Select an existing vendor from suggestions before submitting.")
    }

    // MARK: - Stage 3: Line item submission

    private func stage3SubmitLineItems(
        payload: POSubmissionPayload,
        vendorId: String,
        mode: SubmissionMode?,
        ignoreTaxAndTotals: Bool
    ) async throws -> SubmissionArtifacts {
        _ = ignoreTaxAndTotals
        let candidates = submittableItems(from: payload)
        guard !candidates.isEmpty else {
            throw ValidationError.noSubmittableItems
        }

        let resolvedMode = mode ?? .attachToExistingPO
        switch resolvedMode {
        case .attachToExistingPO:
            if mode == nil {
                // Backward-compatible behavior for legacy callsites/tests.
                guard let orderId = payload.orderId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                      let serviceId = payload.serviceId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                    return .empty
                }

                try await submitAttachModeItems(
                    orderId: orderId,
                    serviceId: serviceId,
                    vendorId: vendorId,
                    purchaseOrderId: nil,
                    items: candidates
                )
                return .empty
            }

            return try await submitDraftPurchaseOrder(
                payload: payload,
                vendorId: vendorId,
                scannedItems: candidates
            )

        case .quickAddToTicket:
            guard let orderId = payload.orderId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                  let serviceId = payload.serviceId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                throw ValidationError.invalidPayload("Quick Add requires both work order ID and service ID.")
            }

            if let inventoryValidationError = quickAddInventoryValidationError(for: candidates) {
                throw ValidationError.invalidPayload(inventoryValidationError)
            }

            let selectedDraftPOID = try await validatedDraftPurchaseOrderID(from: payload.purchaseOrderId)
            try await submitAttachModeItems(
                orderId: orderId,
                serviceId: serviceId,
                vendorId: vendorId,
                purchaseOrderId: selectedDraftPOID,
                items: candidates
            )
            return .empty

        case .inventoryRestock:
            return try await submitDraftPurchaseOrder(
                payload: payload,
                vendorId: vendorId,
                scannedItems: candidates
            )
        }
    }

    private func submitDraftPurchaseOrder(
        payload: POSubmissionPayload,
        vendorId: String,
        scannedItems: [POItem]
    ) async throws -> SubmissionArtifacts {
        let selectedDraftPO = try await resolveDraftPurchaseOrder(
            explicitID: payload.purchaseOrderId,
            scannedPONumber: payload.allowExistingPOLinking ? (payload.poReference ?? payload.poNumber) : nil
        )
        let selectedDraftPOID = selectedDraftPO?.id.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let mergedItems: [POItem]
        var resolvedOrderID = payload.orderId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if let selectedPO = selectedDraftPO {
            let existingItems = poItems(from: selectedPO)
            mergedItems = mergePurchaseOrderItems(existingItems: existingItems, scannedItems: scannedItems)
            if resolvedOrderID == nil {
                resolvedOrderID = selectedPO.orderId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
        } else {
            mergedItems = scannedItems
        }

        let request = buildPurchaseOrderRequest(
            vendorId: vendorId,
            payload: payload,
            purchaseOrderId: selectedDraftPOID,
            orderId: resolvedOrderID,
            items: mergedItems
        )

        let response = try await shopmonkey.createPurchaseOrder(request)
        return SubmissionArtifacts(
            createdPurchaseOrderID: response.id.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            createdPurchaseOrderNumber: response.number?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func validatedDraftPurchaseOrderID(from rawID: String?) async throws -> String? {
        guard let candidateID = rawID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }

        return try await resolveDraftPurchaseOrder(explicitID: candidateID, scannedPONumber: nil)?
            .id
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func resolveDraftPurchaseOrder(
        explicitID rawID: String?,
        scannedPONumber rawNumber: String?
    ) async throws -> PurchaseOrderResponse? {
        if let candidateID = rawID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let all = try await shopmonkey.getPurchaseOrders()
            guard let selectedPO = all.first(where: { candidate in
                candidate.id.trimmingCharacters(in: .whitespacesAndNewlines) == candidateID
            }) else {
                throw ValidationError.invalidPayload("Selected purchase order could not be found. Refresh and select again.")
            }

            guard selectedPO.isDraft else {
                throw ValidationError.invalidPayload("Selected purchase order is not Draft. Choose a Draft PO or create a new one.")
            }

            return selectedPO
        }

        guard let normalizedReference = normalizePurchaseOrderReference(rawNumber) else {
            return nil
        }

        let all = try await shopmonkey.getPurchaseOrders()
        guard let matchedPO = all.first(where: { candidate in
            normalizePurchaseOrderReference(candidate.number) == normalizedReference
        }) else {
            return nil
        }

        guard matchedPO.isDraft else {
            let displayNumber = matchedPO.number?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? matchedPO.id
            throw ValidationError.invalidPayload(
                "Matched purchase order \(displayNumber) is \(matchedPO.status). Only Draft purchase orders can be updated."
            )
        }

        return matchedPO
    }

    private func normalizePurchaseOrderReference(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        let normalized = value
            .uppercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()

        return normalized.isEmpty ? nil : normalized
    }

    private func poItems(from purchaseOrder: PurchaseOrderResponse) -> [POItem] {
        purchaseOrder.allLineItems.map { line in
            POItem(
                description: line.name,
                sku: line.partNumber ?? "",
                quantity: Double(max(1, line.quantity)),
                unitCost: Decimal(max(0, line.costCents)) / 100,
                partNumber: line.partNumber,
                confidence: 1.0,
                kind: itemKind(for: line.kind),
                kindConfidence: 1.0,
                kindReasons: ["Imported from selected draft PO \(purchaseOrder.number ?? purchaseOrder.id)"]
            )
        }
    }

    private func mergePurchaseOrderItems(existingItems: [POItem], scannedItems: [POItem]) -> [POItem] {
        var signatures = Set(existingItems.map(itemSignature))
        var merged = existingItems

        for item in scannedItems {
            let signature = itemSignature(item)
            guard !signatures.contains(signature) else { continue }
            signatures.insert(signature)
            merged.append(item)
        }

        return merged
    }

    private func itemSignature(_ item: POItem) -> String {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let partNumber = (item.partNumber ?? item.sku).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(name)|\(partNumber)|\(item.quantityForSubmission)|\(item.costCents)|\(classify(item).rawValue)"
    }

    private func itemKind(for lineKind: PurchaseOrderResponse.LineItemKind) -> POItemKind {
        switch lineKind {
        case .part:
            return .part
        case .fee:
            return .fee
        case .tire:
            return .tire
        }
    }

    private func quickAddInventoryValidationError(for items: [POItem]) -> String? {
        let missingInventoryIdentifiers = items.filter { item in
            let lineType = classify(item)
            guard lineType == .part || lineType == .tire else { return false }
            let identifier = (item.partNumber ?? item.sku).trimmingCharacters(in: .whitespacesAndNewlines)
            return identifier.isEmpty
        }

        guard !missingInventoryIdentifiers.isEmpty else { return nil }
        return "Quick Add requires a barcode, SKU, or part number on each part/tire line. Use Attach to PO or Restock for non-inventory purchases."
    }

    private func buildPurchaseOrderRequest(
        vendorId: String,
        payload: POSubmissionPayload,
        purchaseOrderId: String?,
        orderId: String?,
        items: [POItem]
    ) -> CreatePurchaseOrderRequest {
        let lineItems = items.map { item in
            let safeDescription = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeSKU = item.sku.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let safePartNumber = item.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? safeSKU
            let unitCostCents = item.costCents
            return CreatePurchaseOrderLineItemRequest(
                description: safeDescription,
                quantity: item.quantityForSubmission,
                unitCostCents: unitCostCents,
                name: safeDescription,
                partNumber: safePartNumber,
                costCents: unitCostCents,
                unitCost: Decimal(unitCostCents) / 100
            )
        }

        let parts = items.compactMap { item -> CreatePurchaseOrderPartRequest? in
            guard classify(item) == .part else { return nil }

            let safeName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeSKU = item.sku.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let safePartNumber = item.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? safeSKU
                ?? fallbackPartNumber(for: safeName, itemID: item.id)
            return CreatePurchaseOrderPartRequest(
                name: safeName,
                quantity: item.quantityForSubmission,
                costCents: item.costCents,
                number: safePartNumber,
                description: safeName,
                partNumber: safePartNumber
            )
        }

        let fees = items.compactMap { item -> CreatePurchaseOrderFeeRequest? in
            guard classify(item) == .fee else { return nil }

            let safeName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let amountCents = max(item.costCents * item.quantityForSubmission, item.costCents)
            return CreatePurchaseOrderFeeRequest(
                name: safeName,
                amountCents: amountCents,
                description: safeName
            )
        }

        let tires = items.compactMap { item -> CreatePurchaseOrderTireRequest? in
            guard classify(item) == .tire else { return nil }

            let safeName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeSKU = item.sku.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let safePartNumber = item.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? safeSKU
                ?? fallbackPartNumber(for: safeName, itemID: item.id)
            return CreatePurchaseOrderTireRequest(
                name: safeName,
                quantity: item.quantityForSubmission,
                costCents: item.costCents,
                number: safePartNumber,
                description: safeName,
                partNumber: safePartNumber
            )
        }

        return CreatePurchaseOrderRequest(
            vendorId: vendorId,
            notes: payload.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            invoiceNumber:
                payload.invoiceNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? payload.poNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            status: "draft",
            purchaseOrderId: purchaseOrderId,
            orderId: orderId,
            lineItems: lineItems,
            parts: parts,
            fees: fees,
            tires: tires
        )
    }

    private func submittableItems(from payload: POSubmissionPayload) -> [POItem] {
        payload.items.filter { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return false }
            if item.costCents == 0 { return false }
            if InvoiceLineClassifier.isNonProductSummaryLine(name) { return false }
            return true
        }
    }

    private func submitAttachModeItems(
        orderId: String,
        serviceId: String,
        vendorId: String,
        purchaseOrderId: String?,
        items: [POItem]
    ) async throws {
        for item in items {
            let description = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            switch classify(item) {
            case .part:
                let request = CreatePartRequest(
                    name: description,
                    quantity: item.quantityForSubmission,
                    partNumber: item.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                    wholesaleCostCents: item.costCents,
                    vendorId: vendorId,
                    purchaseOrderId: purchaseOrderId
                )
                _ = try await shopmonkey.createPart(orderId: orderId, serviceId: serviceId, request: request)

            case .fee:
                let amountCents = max(item.costCents * item.quantityForSubmission, item.costCents)
                let request = CreateFeeRequest(
                    description: description,
                    amountCents: amountCents,
                    purchaseOrderId: purchaseOrderId
                )
                _ = try await shopmonkey.createFee(orderId: orderId, serviceId: serviceId, request: request)

            case .tire:
                let request = CreateTireRequest(
                    description: description,
                    quantity: item.quantityForSubmission,
                    costCents: item.costCents,
                    vendorId: vendorId,
                    purchaseOrderId: purchaseOrderId
                )
                _ = try await shopmonkey.createTire(orderId: orderId, serviceId: serviceId, request: request)
            }
        }
    }

    func classify(_ item: POItem) -> LineItemType {
        switch item.kind {
        case .part:
            return .part
        case .tire:
            return .tire
        case .fee:
            return .fee
        case .unknown:
            break
        }

        let suggestion = LineItemSuggestionService.classify(
            description: item.name,
            partNumber: item.partNumber ?? item.sku,
            contextText: item.name
        )
        if suggestion.confidence >= LineItemSuggestionService.tentativeConfidenceThreshold {
            switch suggestion.kind {
            case .part:
                return .part
            case .tire:
                return .tire
            case .fee:
                return .fee
            case .unknown:
                break
            }
        }

        let desc = item.name
        let normalizedDesc = desc.lowercased()

        if normalizedDesc.range(
            of: #"mount\s*&\s*balance|mount\s+and\s+balance|balance\s+service"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .fee
        }

        if normalizedDesc.range(
            of: #"\b(freight|shipping|core|tax|hazmat|disposal|shop\s+supplies|environmental|surcharge|labor|alignment|install(?:ation)?|mount(?:ing)?)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .fee
        }

        if normalizedDesc.contains("tire")
            || normalizedDesc.range(
                of: #"\b\d{3}/\d{2,3}(?:/\d{2}|(?:zr|r|-)?\d{2})\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
            return .tire
        }

        #if DEBUG
        print("POSubmissionService: defaulted unknown line type to part for item '\(item.name)'")
        #endif
        return .part
    }

    private func fallbackPartNumber(for name: String, itemID: UUID) -> String {
        let alphanumerics = name
            .uppercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()

        if alphanumerics.count >= 4 {
            return String(alphanumerics.prefix(16))
        }

        let suffix = String(itemID.uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        return "ITEM\(suffix)"
    }

    private func bestEffortFetchPurchaseOrders() async -> [PurchaseOrderResponse]? {
        do {
            return try await shopmonkey.getPurchaseOrders()
        } catch {
            return nil
        }
    }

    private func resolveSubmittedPONumber(
        from artifacts: SubmissionArtifacts,
        knownPurchaseOrders: [PurchaseOrderResponse]?
    ) -> String? {
        if let createdPurchaseOrderNumber = artifacts.createdPurchaseOrderNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return createdPurchaseOrderNumber
        }

        guard let createdPurchaseOrderID = artifacts.createdPurchaseOrderID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        guard let knownPurchaseOrders else {
            return nil
        }

        if let matchedByID = knownPurchaseOrders.first(where: { candidate in
            candidate.id.trimmingCharacters(in: .whitespacesAndNewlines) == createdPurchaseOrderID
        }) {
            return matchedByID.number?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        if let normalizedCreatedID = normalizePurchaseOrderReference(createdPurchaseOrderID),
           let matchedByNumber = knownPurchaseOrders.first(where: { candidate in
               normalizePurchaseOrderReference(candidate.number) == normalizedCreatedID
           }) {
            return matchedByNumber.number?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        return nil
    }

    // MARK: - Stage 4: Persist final status

    private func stage4PersistFinalStatus(
        purchaseOrder: PurchaseOrder?,
        status: String,
        message: String?,
        submittedPONumber: String? = nil,
        context: NSManagedObjectContext
    ) {
        guard let purchaseOrder else {
            return
        }

        purchaseOrder.status = status

        if status == "submitted" {
            if let submittedPONumber = submittedPONumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                purchaseOrder.poNumber = submittedPONumber
            }
            purchaseOrder.submittedAt = Date()
            purchaseOrder.lastError = nil
        } else if status == "failed" {
            purchaseOrder.lastError = message
        }

        if context.hasChanges {
            try? context.save()
        }
    }

    private func detailedUserMessage(for error: Error, since start: Date) async -> String {
        let base = userMessage(for: error)
        guard error is APIError || error is URLError else {
            return base
        }

        guard let diagnostics = await NetworkDiagnosticsRecorder.shared.latestFailureSummary(since: start),
              !diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }

        if base.contains(diagnostics) {
            return base
        }
        return "\(base)\n\(diagnostics)"
    }

    private func fetchCachedVendor(normalizedName: String, context: NSManagedObjectContext) -> Vendor? {
        let safe = normalizedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return nil }

        let request: NSFetchRequest<Vendor> = Vendor.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "normalizedName == %@", safe)
        return try? context.fetch(request).first
    }

    private func persistVendor(_ vendor: VendorSummary, context: NSManagedObjectContext) {
        let normalized = vendor.name.normalizedVendorName
        let request: NSFetchRequest<Vendor> = Vendor.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "normalizedName == %@", normalized)

        let existing = (try? context.fetch(request))?.first
        do {
            let record: Vendor
            if let existing {
                record = existing
            } else {
                record = try context.insertObject(Vendor.self)
            }
            record.id = vendor.id
            record.name = vendor.name
            record.normalizedName = normalized
        } catch {
            // Vendor caching should never block submission.
            return
        }

        if context.hasChanges {
            try? context.save()
        }
    }

    private func bestVendorMatch(in results: [VendorSummary], normalizedQuery: String) -> VendorSummary? {
        let query = normalizedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let ranked = VendorMatcher.rankVendors(
            results,
            query: query,
            minimumScore: VendorMatcher.autoSelectScore
        )
        return ranked.first?.vendor
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// User-safe error string mapping. Never include tokens, headers, or URLs.
func userMessage(for error: Error) -> String {
    if let validation = error as? ValidationError {
        switch validation {
        case .invalidPayload(let message):
            return message
        case .invalidVendor:
            return "Vendor name looks like a line item. Please enter a vendor name."
        case .noSubmittableItems:
            return "No valid items to submit."
        }
    }

    if let apiError = error as? APIError {
        switch apiError {
        case .missingToken:
            return "Missing API key"
        case .unauthorized:
            return "Unauthorized"
        case .rateLimited:
            return "Rate limited, retrying"
        case .serverError(let code):
            if code == 400 || code == 422 {
                return "Server rejected request (\(code)). Check vendor, IDs, and line item fields."
            }
            return "Server error (\(code))"
        case .network:
            return "Network unavailable"
        case .invalidURL, .encodingFailed, .decodingFailed:
            return "Unexpected error"
        }
    }

    if error is URLError {
        return "Network unavailable"
    }

    #if DEBUG
    let nsError = error as NSError
    var details = "\(nsError.domain) \(nsError.code)"
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        details += ", underlying: \(underlying.domain) \(underlying.code)"
    }
    return "Unexpected error (\(details))"
    #else
    return "Unexpected error"
    #endif
}
