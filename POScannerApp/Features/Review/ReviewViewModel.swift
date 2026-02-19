//
//  ReviewViewModel.swift
//  POScannerApp
//

import Combine
import CoreData
import Foundation

enum SubmissionMode: String, CaseIterable, Hashable {
    case attachToExistingPO = "Attach to PO"
    case quickAddToTicket = "Quick Add"
    case inventoryRestock = "Restock"
}

@MainActor
final class ReviewViewModel: ObservableObject {
    enum ModeUI: String, CaseIterable, Hashable {
        case attach
        case quickAdd
        case restock
    }

    let environment: AppEnvironment
    let shopmonkeyService: ShopmonkeyServicing
    let parsedInvoice: ParsedInvoice

    @Published var vendorName: String = ""
    @Published var vendorPhone: String = ""
    @Published var vendorInvoiceNumber: String = ""
    @Published var poReference: String = ""
    @Published var notes: String = ""
    @Published private(set) var suggestedVendorName: String?
    @Published private(set) var suggestedInvoiceNumber: String?
    @Published private(set) var suggestedPONumber: String?
    @Published var vendorSuggestions: [VendorSummary] = []
    @Published private(set) var selectedVendorId: String?

    @Published var orderId: String = ""
    @Published var serviceId: String = ""
    @Published var items: [POItem] = [] {
        didSet {
            refreshUnknownKindRate()
        }
    }

    @Published private(set) var typeOverrideCount: Int = 0
    @Published private(set) var unknownKindRate: Double = 0
    @Published private(set) var vendorAutoSelectSuccessRate: Double = 0

    @Published var selectedOrder: OrderSummary?
    @Published var selectedService: ServiceSummary?
    @Published var selectedPurchaseOrder: PurchaseOrderResponse?
    @Published private(set) var purchaseOrderMatchMessage: String?
    @Published var selectedPOId: String?
    @Published var selectedTicketId: String?

    @Published var modeUI: ModeUI = .quickAdd {
        didSet {
            synchronizeForModeChange(from: oldValue, to: modeUI)
        }
    }
    @Published var ignoreTaxOverride: Bool = false

    @Published var isSubmitting: Bool = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var showSuccessAlert: Bool = false

    @Published var focusedItemId: UUID?
    @Published var todayCount: Int = 0
    @Published var todayTotal: Decimal = 0
    @Published private(set) var activeDraftID: UUID?
    @Published private(set) var lastDraftSavedAt: Date?

    private var vendorLookupTask: Task<Void, Never>?
    private var lineItemSuggestionTask: Task<Void, Never>?
    private var purchaseOrderLookupTask: Task<Void, Never>?
    private var todayMetricsTask: Task<Void, Never>?
    private var vendorAutoSelectAttempts: Int = 0
    private var vendorAutoSelectSuccesses: Int = 0
    private var lastSubmissionFingerprint: Int?
    private var lastSubmissionDate: Date?
    private var autoMatchedPurchaseOrderID: String?
    private var draftCreatedAt: Date?
    private var shouldSkipDraftPersistence: Bool = false

    init(
        environment: AppEnvironment,
        parsedInvoice: ParsedInvoice,
        shopmonkeyService: ShopmonkeyServicing? = nil,
        draftSnapshot: ReviewDraftSnapshot? = nil
    ) {
        self.environment = environment
        self.shopmonkeyService = shopmonkeyService ?? environment.shopmonkeyAPI
        self.parsedInvoice = parsedInvoice

        let header = parsedInvoice.header
        let vendorCandidate = Self.trimmedValue(header.vendorName) ?? parsedInvoice.vendorName
        let invoiceCandidate = Self.trimmedValue(header.vendorInvoiceNumber) ?? parsedInvoice.invoiceNumber
        let poCandidate = Self.trimmedValue(header.poReference) ?? parsedInvoice.poNumber

        self.suggestedVendorName = vendorCandidate
        self.suggestedInvoiceNumber = invoiceCandidate
        self.suggestedPONumber = poCandidate

        self.vendorName = Self.isHighConfidenceVendorName(vendorCandidate) ? (vendorCandidate ?? "") : ""
        self.vendorInvoiceNumber = Self.isHighConfidenceDocumentIdentifier(invoiceCandidate) ? (invoiceCandidate ?? "") : ""
        self.poReference = Self.isHighConfidenceDocumentIdentifier(poCandidate) ? (poCandidate ?? "") : ""
        self.orderId = header.workOrderId
        self.serviceId = header.serviceId
        self.notes = header.notes
        self.items = parsedInvoice.items.map { parsed in
            let cents = parsed.costCents ?? 0
            let normalizedSKU = parsed.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return POItem(
                description: parsed.name,
                sku: normalizedSKU,
                quantity: Double(max(1, parsed.quantity ?? 1)),
                unitCost: cents > 0 ? (Decimal(cents) / 100) : 0,
                partNumber: parsed.partNumber,
                confidence: parsed.confidence,
                kind: parsed.kind,
                kindConfidence: parsed.kindConfidence,
                kindReasons: parsed.kindReasons
            )
        }

        refreshUnknownKindRate()

        if !vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleVendorLookup(for: vendorName, debounce: false)
        } else if let suggestedVendorName, !suggestedVendorName.isEmpty {
            scheduleVendorLookup(for: suggestedVendorName, debounce: false)
        }

        let poLookupSeed = Self.trimmedValue(poReference) ?? suggestedPONumber
        if isExperimentalLinkingEnabled, let poLookupSeed, !poLookupSeed.isEmpty {
            schedulePurchaseOrderLookup(for: poLookupSeed, debounce: false)
        }

        if let draftSnapshot {
            restore(from: draftSnapshot)
            if trimmedOrNil(selectedVendorId) == nil, !vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scheduleVendorLookup(for: vendorName, debounce: false)
            }
            if isExperimentalLinkingEnabled, !poReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                schedulePurchaseOrderLookup(for: poReference, debounce: false)
            }
        }

        applyLineItemSuggestions()
    }

    deinit {
        vendorLookupTask?.cancel()
        lineItemSuggestionTask?.cancel()
        purchaseOrderLookupTask?.cancel()
        todayMetricsTask?.cancel()
    }

    var submissionMode: SubmissionMode {
        switch modeUI {
        case .attach:
            return .attachToExistingPO
        case .quickAdd:
            return .quickAddToTicket
        case .restock:
            return .inventoryRestock
        }
    }

    // Backward-compatible alias.
    var poNumber: String? {
        get { trimmedOrNil(poReference) }
        set { setPOReference(newValue ?? "") }
    }

    var confidenceScore: Double {
        averageConfidence
    }

    var totalAmount: Double {
        NSDecimalNumber(decimal: grandTotal).doubleValue
    }

    var subtotal: Decimal {
        items.reduce(.zero) { $0 + $1.subtotal }
    }

    var taxAmount: Decimal {
        guard !shouldIgnoreTax else { return .zero }

        return items
            .filter { $0.isTaxable }
            .reduce(.zero) { $0 + ($1.subtotal * taxRate) }
    }

    var grandTotal: Decimal {
        subtotal + taxAmount
    }

    var shouldIgnoreTax: Bool {
        if ignoreTaxOverride {
            return true
        }

        switch modeUI {
        case .restock:
            return ignoreTaxAndTotalsSetting
        case .attach, .quickAdd:
            return false
        }
    }

    var canSubmit: Bool {
        let vendor = vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vendor.isEmpty else { return false }
        guard trimmedOrNil(selectedVendorId) != nil else { return false }
        guard !items.isEmpty else { return false }

        switch modeUI {
        case .attach:
            if let selectedPOId = trimmedOrNil(selectedPOId) {
                guard selectedPurchaseOrder?.id == selectedPOId else { return false }
                return selectedPurchaseOrder?.isDraft == true
            }
            // Attach mode also supports creating a new draft PO from scan data.
            return true
        case .quickAdd:
            if trimmedOrNil(selectedPOId) != nil, selectedPurchaseOrder?.isDraft != true {
                return false
            }
            return resolvedOrderID != nil
                && resolvedServiceID != nil
                && quickAddMissingInventoryIdentifiersCount == 0
        case .restock:
            if trimmedOrNil(selectedPOId) == nil {
                return true
            }
            return selectedPurchaseOrder?.isDraft == true
        }
    }

    var subtotalFormatted: String {
        currencyFormatter.string(from: NSDecimalNumber(decimal: subtotal)) ?? ""
    }

    var taxFormatted: String {
        currencyFormatter.string(from: NSDecimalNumber(decimal: taxAmount)) ?? ""
    }

    var grandTotalFormatted: String {
        currencyFormatter.string(from: NSDecimalNumber(decimal: grandTotal)) ?? ""
    }

    var todayTotalFormatted: String {
        currencyFormatter.string(from: NSDecimalNumber(decimal: todayTotal)) ?? ""
    }

    var averageConfidence: Double {
        guard !items.isEmpty else { return parsedConfidenceScore }
        let average = items.reduce(0.0) { $0 + $1.confidence } / Double(items.count)
        return max(0, min(1, average))
    }

    var unknownKindCount: Int {
        items.filter { $0.kind == .unknown }.count
    }

    var suggestedKindCount: Int {
        items.filter { $0.isKindConfidenceMedium }.count
    }

    var reviewReadinessScore: Double {
        let trimmedVendor = vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let vendorReady = !trimmedVendor.isEmpty && trimmedOrNil(selectedVendorId) != nil ? 1.0 : 0.0

        let itemReadiness: Double
        if items.isEmpty {
            itemReadiness = 0
        } else {
            let unknownPenalty = Double(unknownKindCount)
            let suggestedPenalty = Double(suggestedKindCount) * 0.5
            let penalty = (unknownPenalty + suggestedPenalty) / Double(items.count)
            itemReadiness = max(0, min(1, 1 - penalty))
        }

        let contextReady: Double
        switch modeUI {
        case .attach:
            if trimmedOrNil(selectedPOId) != nil {
                contextReady = selectedPurchaseOrder?.isDraft == true ? 1 : 0
            } else {
                contextReady = 1
            }
        case .quickAdd:
            let hasTicketContext = resolvedOrderID != nil && resolvedServiceID != nil
            let hasValidLinkedPO = trimmedOrNil(selectedPOId) == nil || selectedPurchaseOrder?.isDraft == true
            contextReady = hasTicketContext && hasValidLinkedPO ? 1 : 0
        case .restock:
            if trimmedOrNil(selectedPOId) == nil {
                contextReady = 1
            } else {
                contextReady = selectedPurchaseOrder?.isDraft == true ? 1 : 0
            }
        }

        return (vendorReady + itemReadiness + contextReady) / 3.0
    }

    var submissionPayload: POSubmissionPayload {
        POSubmissionPayload(
            vendorId: selectedVendorId,
            vendorName: vendorName,
            vendorPhone: trimmedOrNil(vendorPhone),
            invoiceNumber: trimmedOrNil(vendorInvoiceNumber),
            poReference: trimmedOrNil(poReference),
            poNumber: effectivePONumber,
            purchaseOrderId: resolvedPurchaseOrderID,
            orderId: resolvedOrderID,
            serviceId: resolvedServiceID,
            items: items,
            allowExistingPOLinking: experimentalOrderPOLinkingSetting
        )
    }

    var validationMessage: String? {
        submissionPayload.validationMessage
    }

    var modeGuidanceText: String {
        switch modeUI {
        case .attach:
            return "Attach creates or updates a draft purchase order. Only Shopmonkey draft POs can be targeted."
        case .quickAdd:
            return "Quick Add posts inventory lines directly to the selected work order service."
        case .restock:
            return "Restock keeps stock intake on draft purchase orders."
        }
    }

    var parsedConfidenceScore: Double {
        parsedInvoice.confidenceScore
    }

    func addEmptyItem() {
        items.append(POItem(description: ""))
    }

    // Backward-compatible alias.
    func addItem() {
        addEmptyItem()
    }

    func deleteItems(at offsets: IndexSet) {
        removeItems(at: offsets)
    }

    func setItemKind(at index: Int, to newKind: POItemKind) {
        guard items.indices.contains(index) else { return }
        let oldKind = items[index].kind
        guard oldKind != newKind else { return }
        items[index].kind = newKind
        recordTypeOverride(from: oldKind, to: newKind)
    }

    func moveItems(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }

        var reordered = items
        let movingItems = source.sorted().compactMap { index in
            reordered.indices.contains(index) ? reordered[index] : nil
        }

        for index in source.sorted(by: >) where reordered.indices.contains(index) {
            reordered.remove(at: index)
        }

        let removedBeforeDestination = source.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(reordered.count, destination - removedBeforeDestination))
        reordered.insert(contentsOf: movingItems, at: adjustedDestination)
        items = reordered
    }

    func removeItems(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard items.indices.contains(index) else { continue }
            items.remove(at: index)
        }
    }

    func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func selectOrder(_ order: OrderSummary) {
        selectedOrder = order
        orderId = order.id
        modeUI = .quickAdd

        selectedService = nil
        selectedTicketId = nil
        serviceId = ""
    }

    func selectPurchaseOrder(
        _ purchaseOrder: PurchaseOrderResponse,
        forceAttachMode: Bool = false,
        isAutoMatch: Bool = false
    ) {
        selectedPurchaseOrder = purchaseOrder
        selectedPOId = purchaseOrder.id
        autoMatchedPurchaseOrderID = isAutoMatch ? purchaseOrder.id : nil
        if forceAttachMode {
            modeUI = .attach
        }

        if let existingOrderID = trimmedOrNil(purchaseOrder.orderId),
           trimmedOrNil(orderId) == nil {
            orderId = existingOrderID
        }

        if let poNumber = trimmedOrNil(purchaseOrder.number),
           trimmedOrNil(poReference) == nil {
            poReference = poNumber
        }

        if purchaseOrder.isDraft {
            let existingItems = purchaseOrder.allLineItems.map { line in
                POItem(
                    description: line.name,
                    sku: line.partNumber ?? "",
                    quantity: Double(max(1, line.quantity)),
                    unitCost: Decimal(max(0, line.costCents)) / 100,
                    partNumber: line.partNumber,
                    confidence: 1.0,
                    kind: map(kind: line.kind),
                    kindConfidence: 1.0,
                    kindReasons: ["Loaded from draft PO \(purchaseOrder.number ?? purchaseOrder.id)"]
                )
            }
            items = mergeExistingItems(existingItems, into: items)
            errorMessage = nil
            if isAutoMatch {
                purchaseOrderMatchMessage = "Matched draft Shopmonkey PO \(purchaseOrder.number ?? purchaseOrder.id)."
            } else {
                purchaseOrderMatchMessage = nil
            }
        } else {
            errorMessage = "Selected purchase order is \(purchaseOrder.status). Only Draft purchase orders can be updated."
            purchaseOrderMatchMessage = "Matched Shopmonkey PO \(purchaseOrder.number ?? purchaseOrder.id) is \(purchaseOrder.status)."
        }
    }

    func selectService(_ service: ServiceSummary) {
        selectedService = service
        selectedTicketId = service.id
        serviceId = service.id

        if modeUI == .attach, selectedPOId == nil, trimmedOrNil(orderId) == nil {
            modeUI = .quickAdd
        }
    }

    func setOrderIdManually(_ value: String) {
        orderId = value
        selectedOrder = nil

        selectedService = nil
        selectedTicketId = nil
        serviceId = ""
    }

    func setServiceIdManually(_ value: String) {
        serviceId = value
        selectedTicketId = trimmedOrNil(value)
        selectedService = nil
    }

    func setVendorName(_ value: String) {
        vendorName = value
        selectedVendorId = nil
        scheduleVendorLookup(for: value, debounce: true)
    }

    func applySuggestedVendorName() {
        guard let suggestedVendorName, !suggestedVendorName.isEmpty else { return }
        setVendorName(suggestedVendorName)
        scheduleVendorLookup(for: suggestedVendorName, debounce: false)
    }

    func applySuggestedInvoiceNumber() {
        guard let suggestedInvoiceNumber, !suggestedInvoiceNumber.isEmpty else { return }
        vendorInvoiceNumber = suggestedInvoiceNumber
    }

    func applySuggestedPONumber() {
        guard let suggestedPONumber, !suggestedPONumber.isEmpty else { return }
        setPOReference(suggestedPONumber)
    }

    func setPOReference(_ value: String) {
        poReference = value

        guard isExperimentalLinkingEnabled else {
            purchaseOrderLookupTask?.cancel()
            purchaseOrderMatchMessage = nil
            return
        }

        if let selectedPO = selectedPurchaseOrder,
           autoMatchedPurchaseOrderID == selectedPO.id,
           normalizePurchaseOrderReference(value) != normalizePurchaseOrderReference(selectedPO.number) {
            selectedPurchaseOrder = nil
            selectedPOId = nil
            autoMatchedPurchaseOrderID = nil
        }

        schedulePurchaseOrderLookup(for: value, debounce: true)
    }

    func applyProductionPolishMode() {
        if modeUI != .attach {
            modeUI = .attach
        }
        selectedOrder = nil
        selectedService = nil
        selectedTicketId = nil
        serviceId = ""
        selectedPurchaseOrder = nil
        selectedPOId = nil
        autoMatchedPurchaseOrderID = nil
        purchaseOrderMatchMessage = nil
    }

    func saveDraft() async {
        do {
            _ = try await persistDraft(
                showStatusMessage: true,
                workflowState: .reviewEdited,
                workflowDetail: "Review updates saved."
            )
        } catch {
            errorMessage = "Could not save intake draft."
        }
    }

    func persistDraftOnExitIfNeeded() async {
        guard !shouldSkipDraftPersistence else { return }
        guard hasMeaningfulDraftContent else { return }
        _ = try? await persistDraft(
            showStatusMessage: false,
            workflowState: .reviewEdited,
            workflowDetail: "Review updates saved."
        )
    }

    func discardDraft() async {
        guard let draftID = activeDraftID else { return }
        do {
            try await environment.reviewDraftStore.delete(id: draftID)
            activeDraftID = nil
            draftCreatedAt = nil
            lastDraftSavedAt = nil
            statusMessage = "Saved intake draft removed."
        } catch {
            errorMessage = "Could not remove intake draft."
        }
    }

    func selectVendorSuggestion(_ vendor: VendorSummary) {
        vendorLookupTask?.cancel()
        vendorName = vendor.name
        selectedVendorId = vendor.id
        vendorSuggestions = []
    }

    func recordTypeOverride(from oldKind: POItemKind, to newKind: POItemKind) {
        guard oldKind != newKind else { return }
        typeOverrideCount += 1
        #if DEBUG
        print("[ScanDiag][Override] from=\(oldKind.rawValue) to=\(newKind.rawValue) overrideCount=\(typeOverrideCount)")
        #endif
        refreshUnknownKindRate()
    }

    func submitToShopmonkey(saveHistoryEnabled: Bool, ignoreTaxAndTotals: Bool) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        statusMessage = nil
        errorMessage = nil
        showSuccessAlert = false

        _ = try? await persistDraft(
            showStatusMessage: false,
            workflowState: .submitting,
            workflowDetail: "Submitting to Shopmonkey."
        )

        let submitter = POSubmissionService(shopmonkey: shopmonkeyService)
        let result = await submitter.submitNew(
            payload: submissionPayload,
            mode: submissionMode,
            shouldPersist: saveHistoryEnabled,
            context: environment.dataController.viewContext,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )

        if result.succeeded {
            statusMessage = "Repair-order payload submitted to sandbox."
            showSuccessAlert = true
            await environment.localNotificationService.notify(
                .submissionSucceeded(
                    vendor: trimmedOrNil(vendorName),
                    totalCents: submissionTotalCents
                )
            )
            await clearDraftAfterSuccessfulSubmission()
        } else {
            errorMessage = result.message ?? "Submission failed."
            _ = try? await persistDraft(
                showStatusMessage: false,
                workflowState: .failed,
                workflowDetail: result.message ?? "Submission failed."
            )
            await environment.localNotificationService.notify(
                .submissionFailed(message: result.message, draftID: activeDraftID)
            )
        }

        isSubmitting = false
    }

    func submit() async throws {
        guard canSubmit else {
            throw SubmissionExecutionError.failed(submissionGuardMessage)
        }

        await submitToShopmonkey(
            saveHistoryEnabled: saveHistoryEnabledSetting,
            ignoreTaxAndTotals: shouldIgnoreTax
        )

        if let errorMessage {
            throw SubmissionExecutionError.failed(errorMessage)
        }
    }

    @MainActor
    func submitTapped() async {
        guard !isSubmitting else { return }

        let fingerprint = submissionFingerprint
        if let lastSubmissionFingerprint,
           let lastSubmissionDate,
           lastSubmissionFingerprint == fingerprint,
           Date().timeIntervalSince(lastSubmissionDate) < 2 {
            return
        }

        do {
            try await submit()
            if showSuccessAlert {
                lastSubmissionFingerprint = fingerprint
                lastSubmissionDate = Date()
            }
        } catch SubmissionExecutionError.failed(let message) {
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadTodayMetrics() {
        todayMetricsTask?.cancel()
        let dataController = environment.dataController

        todayMetricsTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await dataController.waitUntilLoaded()
            guard !Task.isCancelled else { return }
            let container = dataController.container
            let context = container.newBackgroundContext()
            let hasPurchaseOrderEntity = NSEntityDescription.entity(forEntityName: "PurchaseOrder", in: context) != nil
            guard hasPurchaseOrderEntity else {
                todayCount = 0
                todayTotal = 0
                return
            }
            let metrics = await context.perform { () -> (count: Int, total: Decimal) in
                let startOfDay = Calendar.current.startOfDay(for: Date())
                let request: NSFetchRequest<PurchaseOrder> = PurchaseOrder.fetchRequest()
                request.predicate = NSPredicate(format: "date >= %@", startOfDay as NSDate)

                let results = (try? context.fetch(request)) ?? []
                let total = results.reduce(Decimal.zero) { partial, order in
                    partial + Decimal(order.totalAmount)
                }
                return (results.count, total)
            }

            guard !Task.isCancelled else { return }
            todayCount = metrics.count
            todayTotal = metrics.total
        }
    }

    private func synchronizeForModeChange(from oldValue: ModeUI, to newValue: ModeUI) {
        guard oldValue != newValue else { return }

        switch newValue {
        case .attach:
            break
        case .quickAdd:
            break
        case .restock:
            selectedTicketId = nil
            selectedService = nil
        }
    }

    private func mergeExistingItems(_ existingItems: [POItem], into currentItems: [POItem]) -> [POItem] {
        var merged = existingItems
        var signatures = Set(existingItems.map(itemSignature))

        for item in currentItems {
            let signature = itemSignature(item)
            guard !signatures.contains(signature) else { continue }
            signatures.insert(signature)
            merged.append(item)
        }

        return merged
    }

    private func itemSignature(_ item: POItem) -> String {
        let normalizedName = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPart = (item.partNumber ?? item.sku).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedName)|\(normalizedPart)|\(item.quantityForSubmission)|\(item.costCents)|\(item.kind.rawValue)"
    }

    private func map(kind: PurchaseOrderResponse.LineItemKind) -> POItemKind {
        switch kind {
        case .part:
            return .part
        case .fee:
            return .fee
        case .tire:
            return .tire
        }
    }

    private func applyLineItemSuggestions() {
        lineItemSuggestionTask?.cancel()
        let parsedItems = parsedInvoice.items
        let baselineItems = items
        let service = LineItemSuggestionService(context: environment.dataController.viewContext)

        lineItemSuggestionTask = Task { [weak self] in
            let suggested = await service.suggest(items: baselineItems, parsedItems: parsedItems)
            guard let self, !Task.isCancelled else { return }
            // Do not clobber user edits that happened while suggestions were computing.
            guard self.items == baselineItems else { return }
            self.logSuggestionDiagnostics(before: baselineItems, after: suggested)
            self.items = suggested
        }
    }

    private func logSuggestionDiagnostics(before: [POItem], after: [POItem]) {
        #if DEBUG
        let total = after.count
        let unknownCount = after.filter { $0.kind == .unknown }.count
        let kindChanges = zip(before, after).filter { $0.kind != $1.kind }.count
        let unknownRate = total > 0 ? Double(unknownCount) / Double(total) : 0
        let unknownRateText = String(format: "%.2f", unknownRate * 100)

        print(
            "[ScanDiag][Suggest] total=\(total) kindChanges=\(kindChanges) unknownRate=\(unknownRateText)%"
        )

        for (index, pair) in zip(before, after).enumerated() where pair.0.kind != pair.1.kind {
            let oldItem = pair.0
            let newItem = pair.1
            let confidenceText = String(format: "%.2f", newItem.kindConfidence)
            print(
                "[ScanDiag][Suggest][Item \(index + 1)] '\(newItem.description)' \(oldItem.kind.rawValue)->\(newItem.kind.rawValue) confidence=\(confidenceText)"
            )
        }
        #endif
    }

    private func refreshUnknownKindRate() {
        guard !items.isEmpty else {
            unknownKindRate = 0
            return
        }
        let unknownCount = items.filter { $0.kind == .unknown }.count
        unknownKindRate = Double(unknownCount) / Double(items.count)
    }

    private func scheduleVendorLookup(for rawValue: String, debounce: Bool) {
        vendorLookupTask?.cancel()

        let query = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            vendorSuggestions = []
            selectedVendorId = nil
            return
        }

        vendorLookupTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled, let self else { return }

            do {
                let remote = try await self.shopmonkeyService.searchVendors(name: query)
                guard !Task.isCancelled else { return }

                let ranked = self.rankVendorSuggestions(remote, query: query)
                self.vendorSuggestions = Array(ranked.prefix(8).map(\.vendor))
                self.applyVendorAutoSelectionIfNeeded(ranked, query: query)
            } catch {
                guard !Task.isCancelled else { return }
                self.vendorSuggestions = []
                self.selectedVendorId = nil
            }
        }
    }

    private func schedulePurchaseOrderLookup(for rawValue: String, debounce: Bool) {
        purchaseOrderLookupTask?.cancel()

        let query = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizePurchaseOrderReference(query) != nil else {
            if let selectedPO = selectedPurchaseOrder, autoMatchedPurchaseOrderID == selectedPO.id {
                selectedPurchaseOrder = nil
                selectedPOId = nil
                autoMatchedPurchaseOrderID = nil
            }
            purchaseOrderMatchMessage = nil
            return
        }

        purchaseOrderLookupTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            guard !Task.isCancelled, let self else { return }

            do {
                let purchaseOrders = try await self.shopmonkeyService.getPurchaseOrders()
                guard !Task.isCancelled else { return }
                self.applyPurchaseOrderLookupResult(query: query, purchaseOrders: purchaseOrders)
            } catch {
                guard !Task.isCancelled else { return }
                self.purchaseOrderMatchMessage = nil
            }
        }
    }

    private func applyPurchaseOrderLookupResult(query: String, purchaseOrders: [PurchaseOrderResponse]) {
        guard let match = bestPurchaseOrderMatch(for: query, in: purchaseOrders) else {
            if let selectedPO = selectedPurchaseOrder, autoMatchedPurchaseOrderID == selectedPO.id {
                selectedPurchaseOrder = nil
                selectedPOId = nil
                autoMatchedPurchaseOrderID = nil
            }
            purchaseOrderMatchMessage = "No Shopmonkey PO match for \(query). Attach/Restock will create a new draft PO."
            return
        }

        if match.isDraft {
            selectPurchaseOrder(match, isAutoMatch: true)
            return
        }

        if let selectedPO = selectedPurchaseOrder, autoMatchedPurchaseOrderID == selectedPO.id {
            selectedPurchaseOrder = nil
            selectedPOId = nil
            autoMatchedPurchaseOrderID = nil
        }

        purchaseOrderMatchMessage = "Found Shopmonkey PO \(match.number ?? match.id) in \(match.status). Draft is required to update."
    }

    private func bestPurchaseOrderMatch(for query: String, in purchaseOrders: [PurchaseOrderResponse]) -> PurchaseOrderResponse? {
        guard let normalizedQuery = normalizePurchaseOrderReference(query) else { return nil }
        let matches = purchaseOrders.filter { purchaseOrder in
            normalizePurchaseOrderReference(purchaseOrder.number) == normalizedQuery
        }

        if let draftMatch = matches.first(where: \.isDraft) {
            return draftMatch
        }

        return matches.first
    }

    private func applyVendorAutoSelectionIfNeeded(_ ranked: [RankedVendorMatch], query: String) {
        guard let top = ranked.first else {
            selectedVendorId = nil
            vendorAutoSelectSuccessRate = 0
            return
        }

        if top.score >= VendorMatcher.autoSelectScore {
            vendorAutoSelectAttempts += 1
        }

        let normalizedQuery = query.normalizedVendorName
        let canonicalQuery = VendorMatcher.canonicalVendorName(normalizedQuery)
        let normalizedTop = top.vendor.name.normalizedVendorName
        let canonicalTop = VendorMatcher.canonicalVendorName(normalizedTop)

        let shouldAutoSelect = top.score >= VendorMatcher.autoSelectScore
            && (normalizedTop == normalizedQuery || canonicalTop == canonicalQuery)

        if shouldAutoSelect {
            selectedVendorId = top.vendor.id
            vendorAutoSelectSuccesses += 1

            if normalizedTop == normalizedQuery, vendorName != top.vendor.name {
                vendorName = top.vendor.name
            }
        } else {
            selectedVendorId = nil
        }

        if vendorAutoSelectAttempts > 0 {
            vendorAutoSelectSuccessRate = Double(vendorAutoSelectSuccesses) / Double(vendorAutoSelectAttempts)
        } else {
            vendorAutoSelectSuccessRate = 0
        }
    }

    private func rankVendorSuggestions(_ vendors: [VendorSummary], query: String) -> [RankedVendorMatch] {
        VendorMatcher.rankVendors(vendors, query: query, minimumScore: VendorMatcher.minimumSuggestionScore)
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

    private var effectivePONumber: String? {
        trimmedOrNil(poReference) ?? trimmedOrNil(vendorInvoiceNumber)
    }

    private var resolvedOrderID: String? {
        switch modeUI {
        case .attach:
            return trimmedOrNil(orderId) ?? trimmedOrNil(selectedPurchaseOrder?.orderId)
        case .quickAdd:
            return trimmedOrNil(selectedOrder?.id) ?? trimmedOrNil(orderId)
        case .restock:
            return trimmedOrNil(orderId) ?? trimmedOrNil(selectedPurchaseOrder?.orderId)
        }
    }

    private var resolvedServiceID: String? {
        switch modeUI {
        case .attach:
            return trimmedOrNil(serviceId)
        case .quickAdd:
            return trimmedOrNil(selectedTicketId) ?? trimmedOrNil(serviceId)
        case .restock:
            return trimmedOrNil(serviceId)
        }
    }

    private var resolvedPurchaseOrderID: String? {
        trimmedOrNil(selectedPOId) ?? trimmedOrNil(selectedPurchaseOrder?.id)
    }

    private var submissionGuardMessage: String {
        if trimmedOrNil(selectedVendorId) == nil {
            return "Select an existing vendor from suggestions before submitting."
        }

        switch modeUI {
        case .attach:
            if trimmedOrNil(selectedPOId) != nil, selectedPurchaseOrder?.isDraft != true {
                return "Selected purchase order must be Draft before attaching scan items."
            }
            return "Attach mode submits scan items to a draft PO. Pick a Draft PO or create a new one."
        case .quickAdd:
            if trimmedOrNil(selectedPOId) != nil, selectedPurchaseOrder?.isDraft != true {
                return "Linked purchase order must be Draft."
            }
            if resolvedOrderID == nil || resolvedServiceID == nil {
                return "Quick Add requires both work order ID and service ID."
            }
            if quickAddMissingInventoryIdentifiersCount > 0 {
                return "Quick Add requires barcode/SKU/part # for each part/tire line."
            }
            return "Review line items before submitting."
        case .restock:
            if trimmedOrNil(selectedPOId) != nil, selectedPurchaseOrder?.isDraft != true {
                return "Selected purchase order must be Draft for restock updates."
            }
            return "Restock creates or updates a draft stock PO."
        }
    }

    private var submissionFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(submissionMode)
        hasher.combine(submissionPayload)
        return hasher.finalize()
    }

    private var hasMeaningfulDraftContent: Bool {
        if !items.isEmpty {
            return true
        }

        if trimmedOrNil(vendorName) != nil || trimmedOrNil(vendorInvoiceNumber) != nil || trimmedOrNil(poReference) != nil {
            return true
        }

        return false
    }

    private func restore(from snapshot: ReviewDraftSnapshot) {
        let state = snapshot.state
        vendorName = state.vendorName
        vendorPhone = state.vendorPhone
        vendorInvoiceNumber = state.vendorInvoiceNumber
        poReference = state.poReference
        notes = state.notes
        selectedVendorId = trimmedOrNil(state.selectedVendorId)
        orderId = state.orderId
        serviceId = state.serviceId
        if !state.items.isEmpty {
            items = state.items
        }
        modeUI = ModeUI(rawValue: state.modeUIRawValue) ?? .attach
        ignoreTaxOverride = state.ignoreTaxOverride
        selectedPOId = nil
        selectedTicketId = trimmedOrNil(state.selectedTicketId)
        activeDraftID = snapshot.id
        draftCreatedAt = snapshot.createdAt
        lastDraftSavedAt = snapshot.updatedAt
    }

    @discardableResult
    private func persistDraft(
        showStatusMessage: Bool,
        workflowState: ReviewDraftSnapshot.WorkflowState = .reviewEdited,
        workflowDetail: String? = nil
    ) async throws -> ReviewDraftSnapshot {
        let now = Date()
        let draftID = activeDraftID ?? UUID()
        let createdAt = draftCreatedAt ?? now

        let snapshot = ReviewDraftSnapshot(
            id: draftID,
            createdAt: createdAt,
            updatedAt: now,
            state: ReviewDraftSnapshot.State(
                parsedInvoice: ReviewDraftSnapshot.ParsedInvoiceSnapshot(invoice: parsedInvoice),
                vendorName: vendorName,
                vendorPhone: vendorPhone,
                vendorInvoiceNumber: vendorInvoiceNumber,
                poReference: poReference,
                notes: notes,
                selectedVendorId: selectedVendorId,
                orderId: orderId,
                serviceId: serviceId,
                items: items,
                modeUIRawValue: modeUI.rawValue,
                ignoreTaxOverride: ignoreTaxOverride,
                selectedPOId: selectedPOId,
                selectedTicketId: selectedTicketId,
                workflowStateRawValue: workflowState.rawValue,
                workflowDetail: workflowDetail
            )
        )

        try await environment.reviewDraftStore.upsert(snapshot)
        activeDraftID = draftID
        draftCreatedAt = createdAt
        lastDraftSavedAt = now
        if showStatusMessage {
            statusMessage = "Saved intake draft locally."
        }
        return snapshot
    }

    private func clearDraftAfterSuccessfulSubmission() async {
        shouldSkipDraftPersistence = true
        guard let draftID = activeDraftID else { return }
        try? await environment.reviewDraftStore.delete(id: draftID)
        activeDraftID = nil
        draftCreatedAt = nil
        lastDraftSavedAt = nil
    }

    private func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var quickAddMissingInventoryIdentifiersCount: Int {
        items.filter { item in
            let lineKind = item.kind == .unknown
                ? LineItemSuggestionService.classify(
                    description: item.name,
                    partNumber: item.partNumber ?? item.sku,
                    contextText: item.name
                ).kind
                : item.kind

            guard lineKind == .part || lineKind == .tire else { return false }
            return (item.partNumber ?? item.sku).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .count
    }

    private var saveHistoryEnabledSetting: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "saveHistoryEnabled") == nil {
            return true
        }
        return defaults.bool(forKey: "saveHistoryEnabled")
    }

    private var submissionTotalCents: Int? {
        let total = items.reduce(0) { partial, item in
            partial + (item.costCents * item.quantityForSubmission)
        }
        return total > 0 ? total : nil
    }

    private var ignoreTaxAndTotalsSetting: Bool {
        UserDefaults.standard.bool(forKey: "ignoreTaxAndTotals")
    }

    private var isExperimentalLinkingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "experimentalOrderPOLinking")
    }

    private var experimentalOrderPOLinkingSetting: Bool {
        isExperimentalLinkingEnabled
    }

    private let taxRate: Decimal = Decimal(string: "0.13") ?? (Decimal(13) / Decimal(100))

    private let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter
    }()

    private static func trimmedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isHighConfidenceVendorName(_ value: String?) -> Bool {
        guard let trimmed = trimmedValue(value), trimmed.count >= 3 else {
            return false
        }

        let normalized = trimmed.normalizedVendorName
        guard !normalized.isEmpty else { return false }

        // Avoid promoting likely line-item text into the vendor field.
        let hasLineItemSignal = normalized.contains("qty")
            || normalized.contains("shipping")
            || normalized.contains("tax")
            || normalized.contains("tire")
            || normalized.contains("filter")

        if hasLineItemSignal {
            return false
        }

        return normalized.range(of: #"[a-z]"#, options: .regularExpression) != nil
    }

    private static func isHighConfidenceDocumentIdentifier(_ value: String?) -> Bool {
        guard let trimmed = trimmedValue(value), trimmed.count >= 3 else {
            return false
        }

        let pattern = #"^[A-Z0-9][A-Z0-9\-\/]{2,}$"#
        return trimmed.uppercased().range(of: pattern, options: .regularExpression) != nil
    }

    enum SubmissionExecutionError: Error {
        case failed(String)
    }
}
