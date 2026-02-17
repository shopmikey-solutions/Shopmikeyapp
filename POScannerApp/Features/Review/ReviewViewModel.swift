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
    @Published var selectedPOId: String?
    @Published var selectedTicketId: String?

    @Published var modeUI: ModeUI = .restock {
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

    private var vendorLookupTask: Task<Void, Never>?
    private var lineItemSuggestionTask: Task<Void, Never>?
    private var vendorAutoSelectAttempts: Int = 0
    private var vendorAutoSelectSuccesses: Int = 0

    init(environment: AppEnvironment, parsedInvoice: ParsedInvoice, shopmonkeyService: ShopmonkeyServicing? = nil) {
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

        applyLineItemSuggestions()
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
        set { poReference = newValue ?? "" }
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
            let hasOrder = trimmedOrNil(selectedPOId) != nil || trimmedOrNil(orderId) != nil
            let hasService = trimmedOrNil(selectedTicketId) != nil || trimmedOrNil(serviceId) != nil
            return hasOrder && hasService
        case .quickAdd:
            return true
        case .restock:
            return true
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
            let hasOrder = trimmedOrNil(selectedPOId) != nil || trimmedOrNil(orderId) != nil
            let hasService = trimmedOrNil(selectedTicketId) != nil || trimmedOrNil(serviceId) != nil
            contextReady = hasOrder && hasService ? 1 : 0
        case .quickAdd, .restock:
            contextReady = 1
        }

        return (vendorReady + itemReadiness + contextReady) / 3.0
    }

    var submissionPayload: POSubmissionPayload {
        POSubmissionPayload(
            vendorId: selectedVendorId,
            vendorName: vendorName,
            vendorPhone: trimmedOrNil(vendorPhone),
            poNumber: effectivePONumber,
            orderId: resolvedOrderID,
            serviceId: resolvedServiceID,
            items: items
        )
    }

    var validationMessage: String? {
        submissionPayload.validationMessage
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
        selectedPOId = order.id
        orderId = order.id
        modeUI = .attach

        selectedService = nil
        selectedTicketId = nil
        serviceId = ""
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
        selectedPOId = trimmedOrNil(value)
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
        poReference = suggestedPONumber
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
        isSubmitting = true
        statusMessage = nil
        errorMessage = nil
        showSuccessAlert = false

        let submitter = POSubmissionService(shopmonkey: shopmonkeyService)
        let result = await submitter.submitNew(
            payload: submissionPayload,
            mode: submissionMode,
            shouldPersist: saveHistoryEnabled,
            context: environment.dataController.viewContext,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )

        if result.succeeded {
            statusMessage = "Submitted to sandbox."
            showSuccessAlert = true
        } else {
            errorMessage = result.message ?? "Submission failed."
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
        do {
            try await submit()
        } catch SubmissionExecutionError.failed(let message) {
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadTodayMetrics() {
        let container = environment.dataController.container

        Task(priority: .userInitiated) {
            let context = container.newBackgroundContext()
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

            todayCount = metrics.count
            todayTotal = metrics.total
        }
    }

    private func synchronizeForModeChange(from oldValue: ModeUI, to newValue: ModeUI) {
        guard oldValue != newValue else { return }

        switch newValue {
        case .attach:
            selectedTicketId = nil
            selectedService = nil
        case .quickAdd:
            selectedPOId = nil
            selectedOrder = nil
            orderId = ""
        case .restock:
            selectedPOId = nil
            selectedTicketId = nil
            selectedOrder = nil
            selectedService = nil
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

    private var effectivePONumber: String? {
        trimmedOrNil(vendorInvoiceNumber) ?? trimmedOrNil(poReference)
    }

    private var resolvedOrderID: String? {
        switch modeUI {
        case .attach:
            return trimmedOrNil(selectedPOId) ?? trimmedOrNil(orderId)
        case .quickAdd:
            return nil
        case .restock:
            return trimmedOrNil(orderId)
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

    private var submissionGuardMessage: String {
        if trimmedOrNil(selectedVendorId) == nil {
            return "Select an existing vendor from suggestions before submitting."
        }

        switch modeUI {
        case .attach:
            return "Select an existing PO before submitting."
        case .quickAdd:
            return "Review line items before submitting."
        case .restock:
            return "Review required fields before submitting."
        }
    }

    private func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var saveHistoryEnabledSetting: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "saveHistoryEnabled") == nil {
            return true
        }
        return defaults.bool(forKey: "saveHistoryEnabled")
    }

    private var ignoreTaxAndTotalsSetting: Bool {
        UserDefaults.standard.bool(forKey: "ignoreTaxAndTotals")
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
