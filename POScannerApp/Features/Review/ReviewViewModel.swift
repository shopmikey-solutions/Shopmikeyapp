//
//  ReviewViewModel.swift
//  POScannerApp
//

import Combine
import CoreData
import Foundation
import os

enum SubmissionMode: String, CaseIterable, Hashable {
    case attachToExistingPO = "Attach to PO"
    case quickAddToTicket = "Quick Add"
    case inventoryRestock = "Restock"
}

@MainActor
final class ReviewViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.Review")
    private static var sharedVendorLookupCache: [String: [VendorSummary]] = [:]

    enum ModeUI: String, CaseIterable, Hashable {
        case attach
        case quickAdd
        case restock
    }

    let environment: AppEnvironment
    let shopmonkeyService: ShopmonkeyServicing
    let parsedInvoice: ParsedInvoice

    @Published var vendorName: String = "" {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }
    @Published var vendorPhone: String = "" {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }
    @Published var vendorEmail: String = "" {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }
    @Published var vendorNotes: String = "" {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }
    @Published var vendorInvoiceNumber: String = "" {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }
    @Published var poReference: String = "" {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }
    @Published var notes: String = "" {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }
    @Published private(set) var suggestedVendorName: String?
    @Published private(set) var suggestedInvoiceNumber: String?
    @Published private(set) var suggestedPONumber: String?
    @Published var vendorSuggestions: [VendorSummary] = []
    @Published private(set) var selectedVendorId: String? {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }

    @Published var orderId: String = "" {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }
    @Published var serviceId: String = "" {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }
    @Published var items: [POItem] = [] {
        didSet {
            refreshUnknownKindRate()
            scheduleDraftAutosaveIfNeeded()
        }
    }

    @Published private(set) var typeOverrideCount: Int = 0
    @Published private(set) var unknownKindRate: Double = 0
    @Published private(set) var vendorAutoSelectSuccessRate: Double = 0

    @Published var selectedOrder: OrderSummary?
    @Published var selectedService: ServiceSummary?
    @Published var selectedPurchaseOrder: PurchaseOrderResponse?
    @Published private(set) var purchaseOrderMatchMessage: String?
    @Published var selectedPOId: String? {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }
    @Published var selectedTicketId: String? {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }

    @Published var modeUI: ModeUI = .quickAdd {
        didSet {
            synchronizeForModeChange(from: oldValue, to: modeUI)
            scheduleDraftAutosaveIfNeeded()
        }
    }
    @Published var ignoreTaxOverride: Bool = false {
        didSet { scheduleDraftAutosaveIfNeeded() }
    }

    @Published var isSubmitting: Bool = false
    @Published private(set) var isCreatingVendor: Bool = false
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
    private var submissionActivityEndTask: Task<Void, Never>?
    private var draftAutosaveTask: Task<Void, Never>?
    private var lastVendorLookupQuery: String?
    private var lastVendorLookupAt: Date?
    private var inFlightVendorLookupQuery: String?
    private var vendorLookupCache: [String: [VendorSummary]] = [:]
    private var vendorAutoSelectAttempts: Int = 0
    private var vendorAutoSelectSuccesses: Int = 0
    private var lastSubmissionFingerprint: Int?
    private var lastSubmissionDate: Date?
    private var autoMatchedPurchaseOrderID: String?
    private var draftCreatedAt: Date?
    private var lastDraftFingerprint: Int?
    private var isRestoringDraftState: Bool = false
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
        self.vendorPhone = Self.trimmedValue(header.vendorPhone) ?? ""
        self.vendorEmail = Self.trimmedValue(header.vendorEmail) ?? ""
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
        vendorLookupCache = Self.sharedVendorLookupCache

        if !vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleVendorLookup(for: vendorName, debounce: false)
        } else if let suggestedVendorName, !suggestedVendorName.isEmpty {
            scheduleVendorLookup(for: suggestedVendorName, debounce: false)
        }

        let poLookupSeed = Self.trimmedValue(poReference) ?? suggestedPONumber
        if isExperimentalLinkingEnabled, let poLookupSeed, !poLookupSeed.isEmpty {
            schedulePurchaseOrderLookup(for: poLookupSeed, debounce: false)
        }

        var shouldApplyInitialSuggestions = true
        if let draftSnapshot {
            restore(from: draftSnapshot)
            shouldApplyInitialSuggestions = false
            if trimmedOrNil(selectedVendorId) == nil, !vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scheduleVendorLookup(for: vendorName, debounce: false)
            }
            if isExperimentalLinkingEnabled, !poReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                schedulePurchaseOrderLookup(for: poReference, debounce: false)
            }
        }

        if shouldApplyInitialSuggestions {
            applyLineItemSuggestions()
        }
    }

    deinit {
        Self.logger.debug("ReviewViewModel deinit: cancelling outstanding tasks.")
        vendorLookupTask?.cancel()
        lineItemSuggestionTask?.cancel()
        purchaseOrderLookupTask?.cancel()
        todayMetricsTask?.cancel()
        submissionActivityEndTask?.cancel()
        draftAutosaveTask?.cancel()
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

    var canCreateVendorFromCurrentInput: Bool {
        trimmedOrNil(vendorName) != nil
            && trimmedOrNil(selectedVendorId) == nil
            && !isCreatingVendor
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
            notes: trimmedOrNil(notes),
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
        let trimmedCurrent = vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIncoming = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCurrent != trimmedIncoming else { return }
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
        draftAutosaveTask?.cancel()
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
        draftAutosaveTask?.cancel()
        draftAutosaveTask = nil
        await persistDraftIfNeeded(
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
            lastDraftFingerprint = nil
            statusMessage = "Saved intake draft removed."
        } catch {
            errorMessage = "Could not remove intake draft."
        }
    }

    func selectVendorSuggestion(_ vendor: VendorSummary) {
        vendorLookupTask?.cancel()
        selectVendor(vendor, adoptVendorName: true, replaceContactDetails: true)
    }

    func createVendorFromCurrentInput() async {
        guard !isCreatingVendor else { return }
        guard let requestedVendorName = trimmedOrNil(vendorName) else {
            errorMessage = "Enter a vendor name before creating a new vendor."
            return
        }

        isCreatingVendor = true
        defer { isCreatingVendor = false }

        let request = CreateVendorRequest(
            name: requestedVendorName,
            phone: trimmedOrNil(vendorPhone),
            email: trimmedOrNil(vendorEmail),
            notes: trimmedOrNil(vendorNotes)
        )

        do {
            let created = try await shopmonkeyService.createVendor(request)
            let createdVendor = VendorSummary(
                id: created.id,
                name: created.name,
                phone: request.phone,
                email: request.email,
                notes: request.notes
            )
            selectVendor(createdVendor, adoptVendorName: true, replaceContactDetails: true)
            statusMessage = "Vendor created and selected."
            errorMessage = nil
        } catch {
            errorMessage = "Could not create vendor. Verify vendor details and try again."
        }
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
        publishSubmissionLiveActivity(
            isActive: true,
            statusText: "Submitting PO • Step 4 of 4",
            detailText: "Posting reviewed draft to Shopmonkey.",
            progress: 0.96
        )

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
            publishSubmissionLiveActivity(
                isActive: true,
                statusText: "Submitted",
                detailText: "Draft moved to submitted successfully.",
                progress: 1.0
            )
            scheduleLiveActivityEnd(after: 1.4)
            await environment.localNotificationService.notify(
                .submissionSucceeded(
                    vendor: trimmedOrNil(vendorName),
                    totalCents: submissionTotalCents
                )
            )
            await clearDraftAfterSuccessfulSubmission()
        } else {
            errorMessage = result.message ?? "Submission failed."
            publishSubmissionLiveActivity(
                isActive: true,
                statusText: "Submission failed • Step 4 of 4",
                detailText: result.message ?? "Review vendor and line item details.",
                progress: 0.55
            )
            scheduleLiveActivityEnd(after: 2.0)
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

    private func publishSubmissionLiveActivity(
        isActive: Bool,
        statusText: String,
        detailText: String,
        progress: Double
    ) {
        let draftURL: URL? = {
            if let activeDraftID {
                return AppDeepLink.scanURL(draftID: activeDraftID)
            }
            return AppDeepLink.historyURL
        }()

        PartsIntakeLiveActivityBridge.sync(
            isActive: isActive,
            statusText: statusText,
            detailText: detailText,
            progress: progress,
            deepLinkURL: draftURL
        )
    }

    private func scheduleLiveActivityEnd(after delay: TimeInterval) {
        submissionActivityEndTask?.cancel()
        submissionActivityEndTask = Task { [weak self] in
            let nanos = UInt64((max(0, delay) * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.publishSubmissionLiveActivity(
                    isActive: false,
                    statusText: "",
                    detailText: "",
                    progress: 0
                )
            }
        }
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
        if todayMetricsTask != nil {
            Self.logger.debug("Cancelling previous review metrics task before reloading.")
        }
        todayMetricsTask?.cancel()
        let dataController = environment.dataController

        todayMetricsTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            Self.logger.debug("Loading review metrics for current day.")
            await dataController.waitUntilLoaded()
            guard !Task.isCancelled else {
                Self.logger.debug("Review metrics task cancelled before Core Data fetch.")
                return
            }
            let container = dataController.container
            let context = container.newBackgroundContext()
            let hasPurchaseOrderEntity = NSEntityDescription.entity(forEntityName: "PurchaseOrder", in: context) != nil
            guard hasPurchaseOrderEntity else {
                Self.logger.error("PurchaseOrder entity missing while loading review metrics.")
                todayCount = 0
                todayTotal = 0
                return
            }
            let metrics = await context.perform { () -> (count: Int, total: Decimal) in
                let startOfDay = Calendar.current.startOfDay(for: Date())
                let request: NSFetchRequest<PurchaseOrder> = PurchaseOrder.fetchRequest()
                request.predicate = NSPredicate(format: "date >= %@", startOfDay as NSDate)

                let results = (try? context.fetch(request)) ?? []
                var trackedCount = 0
                let total = results.reduce(Decimal.zero) { partial, order in
                    let bucket = PurchaseOrderStatusBucket.from(order)
                    guard bucket.countsAsTrackedScan else { return partial }
                    trackedCount += 1
                    return partial + Decimal(order.totalAmount)
                }
                return (trackedCount, total)
            }

            guard !Task.isCancelled else {
                Self.logger.debug("Review metrics task cancelled after Core Data fetch.")
                return
            }
            todayCount = metrics.count
            todayTotal = metrics.total
            Self.logger.debug("Loaded review metrics scans=\(metrics.count, privacy: .public).")
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
        let query = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let minimumLength = debounce ? 3 : 2
        guard query.count >= minimumLength else {
            vendorLookupTask?.cancel()
            inFlightVendorLookupQuery = nil
            vendorSuggestions = []
            selectedVendorId = nil
            return
        }

        let normalizedQuery = query.normalizedVendorName
        if inFlightVendorLookupQuery == normalizedQuery {
            return
        }

        vendorLookupTask?.cancel()
        inFlightVendorLookupQuery = nil

        if let cachedVendors = vendorLookupCache[normalizedQuery] {
            let ranked = rankVendorSuggestions(cachedVendors, query: query)
            vendorSuggestions = Array(ranked.prefix(8).map(\.vendor))
            applyVendorAutoSelectionIfNeeded(ranked, query: query)
            lastVendorLookupQuery = normalizedQuery
            lastVendorLookupAt = Date()
            return
        }

        if debounce,
           let previousQuery = lastVendorLookupQuery,
           previousQuery.count >= 4,
           normalizedQuery.hasPrefix(previousQuery),
           let lastVendorLookupAt,
           Date().timeIntervalSince(lastVendorLookupAt) < 2.0,
           let previousResults = vendorLookupCache[previousQuery] {
            let ranked = rankVendorSuggestions(previousResults, query: query)
            vendorSuggestions = Array(ranked.prefix(8).map(\.vendor))
            applyVendorAutoSelectionIfNeeded(ranked, query: query)
            lastVendorLookupQuery = normalizedQuery
            self.lastVendorLookupAt = Date()
            return
        }

        if lastVendorLookupQuery == normalizedQuery,
           let lastVendorLookupAt,
           Date().timeIntervalSince(lastVendorLookupAt) < 4.0 {
            return
        }

        vendorLookupTask = Task { [weak self] in
            self?.inFlightVendorLookupQuery = normalizedQuery
            defer {
                if self?.inFlightVendorLookupQuery == normalizedQuery {
                    self?.inFlightVendorLookupQuery = nil
                }
            }
            if debounce {
                try? await Task.sleep(nanoseconds: 420_000_000)
            }
            guard !Task.isCancelled, let self else { return }

            do {
                if debounce,
                   let previousQuery = self.lastVendorLookupQuery,
                   normalizedQuery.hasPrefix(previousQuery),
                   let lastLookupAt = self.lastVendorLookupAt,
                   Date().timeIntervalSince(lastLookupAt) < 1.1,
                   let previousResults = self.vendorLookupCache[previousQuery] {
                    let ranked = self.rankVendorSuggestions(previousResults, query: query)
                    self.vendorSuggestions = Array(ranked.prefix(8).map(\.vendor))
                    self.applyVendorAutoSelectionIfNeeded(ranked, query: query)
                    self.lastVendorLookupQuery = normalizedQuery
                    self.lastVendorLookupAt = Date()
                    return
                }

                let remote = try await self.shopmonkeyService.searchVendors(name: query)
                guard !Task.isCancelled else { return }

                let ranked = self.rankVendorSuggestions(remote, query: query)
                self.vendorLookupCache[normalizedQuery] = remote
                Self.sharedVendorLookupCache[normalizedQuery] = remote
                self.lastVendorLookupQuery = normalizedQuery
                self.lastVendorLookupAt = Date()
                self.vendorSuggestions = Array(ranked.prefix(8).map(\.vendor))
                self.applyVendorAutoSelectionIfNeeded(ranked, query: query)
            } catch {
                guard !Task.isCancelled else { return }
                self.lastVendorLookupQuery = normalizedQuery
                self.lastVendorLookupAt = Date()
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
            let shouldAdoptVendorName = normalizedTop == normalizedQuery
            selectVendor(
                top.vendor,
                adoptVendorName: shouldAdoptVendorName,
                replaceContactDetails: false
            )
            vendorAutoSelectSuccesses += 1
        } else {
            selectedVendorId = nil
        }

        if vendorAutoSelectAttempts > 0 {
            vendorAutoSelectSuccessRate = Double(vendorAutoSelectSuccesses) / Double(vendorAutoSelectAttempts)
        } else {
            vendorAutoSelectSuccessRate = 0
        }
    }

    private func selectVendor(
        _ vendor: VendorSummary,
        adoptVendorName: Bool,
        replaceContactDetails: Bool
    ) {
        selectedVendorId = vendor.id
        if adoptVendorName {
            vendorName = vendor.name
        }
        applyVendorContactDetails(from: vendor, replaceExistingValues: replaceContactDetails)
        vendorSuggestions = []
    }

    private func applyVendorContactDetails(from vendor: VendorSummary, replaceExistingValues: Bool) {
        let incomingPhone = trimmedOrNil(vendor.phone)
        let incomingEmail = trimmedOrNil(vendor.email)
        let incomingNotes = trimmedOrNil(vendor.notes)

        if replaceExistingValues || trimmedOrNil(vendorPhone) == nil {
            vendorPhone = incomingPhone ?? ""
        }

        if replaceExistingValues || trimmedOrNil(vendorEmail) == nil {
            vendorEmail = incomingEmail ?? ""
        }

        if replaceExistingValues || trimmedOrNil(vendorNotes) == nil {
            vendorNotes = incomingNotes ?? ""
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
            return "Select or create a vendor before submitting."
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

    private var draftFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(vendorName.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(vendorPhone.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(vendorEmail.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(vendorNotes.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(vendorInvoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(poReference.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(trimmedOrNil(selectedVendorId))
        hasher.combine(orderId.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(serviceId.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(modeUI.rawValue)
        hasher.combine(ignoreTaxOverride)
        hasher.combine(trimmedOrNil(selectedPOId))
        hasher.combine(trimmedOrNil(selectedTicketId))
        hasher.combine(items)
        return hasher.finalize()
    }

    private func scheduleDraftAutosaveIfNeeded() {
        guard !isRestoringDraftState else { return }
        guard !shouldSkipDraftPersistence else { return }
        guard !isSubmitting else { return }
        guard hasMeaningfulDraftContent else { return }

        let fingerprint = draftFingerprint
        guard lastDraftFingerprint != fingerprint else { return }

        draftAutosaveTask?.cancel()
        draftAutosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.persistDraftIfNeeded(
                workflowState: .reviewEdited,
                workflowDetail: "Review updates autosaved."
            )
        }
    }

    private func persistDraftIfNeeded(
        workflowState: ReviewDraftSnapshot.WorkflowState,
        workflowDetail: String?
    ) async {
        guard !isRestoringDraftState else { return }
        guard !shouldSkipDraftPersistence else { return }
        guard hasMeaningfulDraftContent else { return }

        let fingerprint = draftFingerprint
        guard lastDraftFingerprint != fingerprint else { return }

        _ = try? await persistDraft(
            showStatusMessage: false,
            workflowState: workflowState,
            workflowDetail: workflowDetail
        )
    }

    private var hasMeaningfulDraftContent: Bool {
        if !items.isEmpty {
            return true
        }

        if trimmedOrNil(vendorName) != nil
            || trimmedOrNil(vendorPhone) != nil
            || trimmedOrNil(vendorEmail) != nil
            || trimmedOrNil(vendorNotes) != nil
            || trimmedOrNil(vendorInvoiceNumber) != nil
            || trimmedOrNil(poReference) != nil
            || trimmedOrNil(notes) != nil {
            return true
        }

        return false
    }

    private func restore(from snapshot: ReviewDraftSnapshot) {
        draftAutosaveTask?.cancel()
        isRestoringDraftState = true
        defer { isRestoringDraftState = false }

        let state = snapshot.state
        vendorName = state.vendorName
        vendorPhone = state.vendorPhone
        vendorEmail = state.vendorEmail ?? ""
        vendorNotes = state.vendorNotes ?? ""
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
        lastDraftFingerprint = draftFingerprint
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
                vendorEmail: trimmedOrNil(vendorEmail),
                vendorNotes: trimmedOrNil(vendorNotes),
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
        lastDraftFingerprint = draftFingerprint
        if showStatusMessage {
            statusMessage = "Saved intake draft locally."
        }
        return snapshot
    }

    private func clearDraftAfterSuccessfulSubmission() async {
        draftAutosaveTask?.cancel()
        draftAutosaveTask = nil
        shouldSkipDraftPersistence = true
        guard let draftID = activeDraftID else { return }
        try? await environment.reviewDraftStore.delete(id: draftID)
        activeDraftID = nil
        draftCreatedAt = nil
        lastDraftSavedAt = nil
        lastDraftFingerprint = nil
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
