//
//  ScanViewModel.swift
//  POScannerApp
//

import Foundation
import Combine
import CoreGraphics
import CoreData
import ImageIO
import UIKit
import os

@MainActor
final class ScanViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.Scan")

    enum ProcessingStage: String {
        case extractingText = "Reading parts invoice"
        case preparingReview = "Preparing technician review"
        case parsing = "Classifying parts, tires, and fees"
        case finalizing = "Staging purchase order intake"

        var progressEstimate: Double {
            switch self {
            case .extractingText:
                return 0.28
            case .preparingReview:
                return 0.45
            case .parsing:
                return 0.64
            case .finalizing:
                return 0.9
            }
        }

        var detail: String {
            switch self {
            case .extractingText:
                return "Running on-device Vision OCR across the scan."
            case .preparingReview:
                return "Preparing highlighted text and barcode regions."
            case .parsing:
                return "Applying on-device AI + rules for automotive line items."
            case .finalizing:
                return "Final checks before opening the purchase-order review screen."
            }
        }
    }

    let environment: AppEnvironment

    struct ParsedInvoiceRoute: Hashable {
        let id: UUID = UUID()
        let invoice: ParsedInvoice
        let draftSnapshot: ReviewDraftSnapshot?
    }

    struct OCRReviewDraft: Identifiable {
        let id: UUID = UUID()
        let draftID: UUID
        let image: UIImage
        let extraction: OCRService.DocumentExtraction
        let ignoreTaxAndTotals: Bool
    }

    struct RecentSummary: Hashable {
        let vendor: String
        let total: String
        let date: String
    }

    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    @Published var parsedInvoiceRoute: ParsedInvoiceRoute?
    @Published var ocrReviewDraft: OCRReviewDraft?
    @Published private(set) var processingStartedAt: Date?
    @Published private(set) var processingStage: ProcessingStage?
    @Published var todayCount: Int = 0
    @Published var todayTotal: Decimal = 0
    @Published var pendingCount: Int = 0
    @Published var submittedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var mostRecentSummary: RecentSummary?
    @Published var inProgressDrafts: [ReviewDraftSnapshot] = []

    private let minimumOCRFlowDuration: TimeInterval = 0.85
    private let minimumParseFlowDuration: TimeInterval = 1.15
    private var activeWorkflowDraftID: UUID?
    private var cachedOCRReviewDrafts: [UUID: OCRReviewDraft] = [:]
    private var todayMetricsTask: Task<Void, Never>?
    private var inProgressDraftsTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    deinit {
        Self.logger.debug("ScanViewModel deinit: cancelling background metric/draft tasks.")
        todayMetricsTask?.cancel()
        inProgressDraftsTask?.cancel()
    }

    func handleScannedImage(
        _ image: UIImage,
        orientation: CGImagePropertyOrientation,
        ignoreTaxAndTotals: Bool
    ) {
        guard !isProcessing else { return }
        errorMessage = nil
        Task {
            await processScannedImage(
                image,
                orientation: orientation,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
        }
    }

    func handleScannedImage(_ image: UIImage, ignoreTaxAndTotals: Bool) {
        handleScannedImage(
            image,
            orientation: image.imageOrientation.cgImagePropertyOrientation,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
    }

    func handleScannedImage(_ cgImage: CGImage, orientation: CGImagePropertyOrientation, ignoreTaxAndTotals: Bool) {
        let previewImage = UIImage(cgImage: cgImage, scale: 1, orientation: orientation.uiImageOrientation)
        handleScannedImage(
            previewImage,
            orientation: orientation,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
    }

    func cancelOCRReview() {
        ocrReviewDraft = nil
    }

    func continueFromOCRReview(editedText: String, includeDetectedBarcodes: Bool) {
        guard !isProcessing else { return }
        guard let draft = ocrReviewDraft else { return }
        activeWorkflowDraftID = draft.draftID
        cachedOCRReviewDrafts[draft.draftID] = nil
        ocrReviewDraft = nil

        let barcodes = includeDetectedBarcodes ? draft.extraction.barcodes : []
        Task {
            await parseReviewedText(
                editedText,
                barcodeHints: barcodes,
                ignoreTaxAndTotals: draft.ignoreTaxAndTotals
            )
        }
    }

    private func parseReviewedText(
        _ reviewedText: String,
        barcodeHints: [OCRService.DetectedBarcode],
        ignoreTaxAndTotals: Bool
    ) async {
        let baseText = reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseText.isEmpty else {
            errorMessage = "No readable invoice text was found."
            await upsertWorkflowDraft(
                stage: .failed,
                parsedInvoice: makeWorkflowPlaceholderInvoice(),
                items: [],
                detail: errorMessage
            )
            await environment.localNotificationService.notify(.scanFailed)
            return
        }

        errorMessage = nil
        isProcessing = true
        let flowStart = Date()
        processingStartedAt = flowStart
        processingStage = .parsing

        await upsertWorkflowDraft(
            stage: .parsing,
            parsedInvoice: makeWorkflowPlaceholderInvoice(),
            items: [],
            detail: "Classifying parts and fees."
        )

        let handoffService = environment.parseHandoffService
        let parser = environment.poParser
        let (handoff, rulesInvoice) = await Self.computeRulesInvoice(
            reviewedText: baseText,
            barcodeHints: barcodeHints,
            ignoreTaxAndTotals: ignoreTaxAndTotals,
            handoffService: handoffService,
            parser: parser
        )
        let aiEligible = shouldRunOnDeviceAI(rulesInvoice: rulesInvoice, handoff: handoff)

        let ai: ParsedInvoice?
        if aiEligible {
            ai = await environment.foundationModelService.parseInvoiceIfAvailable(
                from: handoff.modelInputText,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
        } else {
            ai = nil
        }

        let invoice = mergedParsedInvoice(aiInvoice: ai, rulesInvoice: rulesInvoice)
        processingStage = .finalizing
        logScanDiagnostics(
            handoff: handoff,
            invoice: invoice,
            rulesInvoice: rulesInvoice,
            aiEligible: aiEligible,
            usedAI: ai != nil,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
        await ensureMinimumProcessingDuration(since: flowStart, minimum: minimumParseFlowDuration)
        let draftSnapshot = await upsertWorkflowDraft(
            stage: .reviewReady,
            parsedInvoice: invoice,
            items: mapPOItems(from: invoice.items),
            detail: "Review ready."
        )
        if let draftID = draftSnapshot?.id {
            cachedOCRReviewDrafts[draftID] = nil
        } else if let activeWorkflowDraftID {
            cachedOCRReviewDrafts[activeWorkflowDraftID] = nil
        }
        parsedInvoiceRoute = ParsedInvoiceRoute(invoice: invoice, draftSnapshot: draftSnapshot)
        await environment.localNotificationService.notify(
            .scanReadyForReview(
                vendor: invoice.vendorName,
                lineItemCount: invoice.items.count,
                draftID: draftSnapshot?.id
            )
        )

        isProcessing = false
        processingStage = nil
        processingStartedAt = nil
    }

    private nonisolated static func computeRulesInvoice(
        reviewedText: String,
        barcodeHints: [OCRService.DetectedBarcode],
        ignoreTaxAndTotals: Bool,
        handoffService: LocalParseHandoffService,
        parser: POParser
    ) async -> (ParseHandoffPayload, ParsedInvoice) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let handoff = handoffService.build(
                    reviewedText: reviewedText,
                    barcodeHints: barcodeHints
                )
                let rulesInvoice = parser.parse(
                    from: handoff.rulesInputText,
                    ignoreTaxAndTotals: ignoreTaxAndTotals
                )
                continuation.resume(returning: (handoff, rulesInvoice))
            }
        }
    }

    var uiTestReviewFixtureEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-test-review-fixture")
    }

    func openUITestReviewFixture() {
        guard uiTestReviewFixtureEnabled else { return }
        parsedInvoiceRoute = ParsedInvoiceRoute(invoice: Self.uiTestReviewInvoice, draftSnapshot: nil)
    }

    func loadInProgressDrafts() {
        if inProgressDraftsTask != nil {
            Self.logger.debug("Cancelling previous in-progress drafts task before reloading.")
        }
        inProgressDraftsTask?.cancel()
        inProgressDraftsTask = Task { [weak self] in
            guard let self else { return }
            Self.logger.debug("Loading in-progress drafts.")
            let drafts = await environment.reviewDraftStore.list()
            guard !Task.isCancelled else {
                Self.logger.debug("In-progress drafts task cancelled before state update.")
                return
            }
            inProgressDrafts = drafts
            Self.logger.debug("Loaded in-progress drafts count=\(drafts.count, privacy: .public).")
        }
    }

    var latestDraft: ReviewDraftSnapshot? {
        inProgressDrafts.first
    }

    var latestResumableDraft: ReviewDraftSnapshot? {
        inProgressDrafts.first(where: \.canResumeInReview)
    }

    func canResumeOCRReview(_ draft: ReviewDraftSnapshot) -> Bool {
        draft.workflowState == .ocrReview && cachedOCRReviewDrafts[draft.id] != nil
    }

    func resumeOCRReview(_ draft: ReviewDraftSnapshot) {
        guard let cached = cachedOCRReviewDrafts[draft.id] else { return }
        activeWorkflowDraftID = draft.id
        parsedInvoiceRoute = nil
        ocrReviewDraft = cached
    }

    func resumeDraft(_ draft: ReviewDraftSnapshot) {
        activeWorkflowDraftID = draft.id
        parsedInvoiceRoute = ParsedInvoiceRoute(invoice: draft.state.parsedInvoice.parsedInvoice, draftSnapshot: draft)
    }

    @discardableResult
    func resumeDraft(id: UUID) async -> Bool {
        guard let draft = await environment.reviewDraftStore.load(id: id) else { return false }
        if canResumeOCRReview(draft) {
            resumeOCRReview(draft)
            return true
        }
        guard draft.canResumeInReview else { return false }
        resumeDraft(draft)
        return true
    }

    func deleteDraft(_ draft: ReviewDraftSnapshot) {
        Task {
            do {
                try await environment.reviewDraftStore.delete(id: draft.id)
                if activeWorkflowDraftID == draft.id {
                    activeWorkflowDraftID = nil
                }
                cachedOCRReviewDrafts[draft.id] = nil
                inProgressDrafts = await environment.reviewDraftStore.list()
            } catch {
                errorMessage = "Could not remove saved intake draft."
            }
        }
    }

    private func processScannedImage(
        _ image: UIImage,
        orientation: CGImagePropertyOrientation,
        ignoreTaxAndTotals: Bool
    ) async {
        activeWorkflowDraftID = UUID()
        isProcessing = true
        errorMessage = nil
        let flowStart = Date()
        processingStartedAt = flowStart
        processingStage = .extractingText
        await upsertWorkflowDraft(
            stage: .scanning,
            parsedInvoice: makeWorkflowPlaceholderInvoice(),
            items: [],
            detail: "Running OCR on captured invoice."
        )

        do {
            let previewImage = await Self.makePreviewImage(from: image)
            guard let cgImage = await Self.makeCGImage(from: image) else {
                errorMessage = "Could not process the invoice scan."
                await environment.localNotificationService.notify(.scanFailed)
                await upsertWorkflowDraft(
                    stage: .failed,
                    parsedInvoice: makeWorkflowPlaceholderInvoice(),
                    items: [],
                    detail: errorMessage
                )
                isProcessing = false
                processingStage = nil
                processingStartedAt = nil
                return
            }
            let extraction = try await environment.ocrService.extractDocument(from: cgImage, orientation: orientation)
            processingStage = .preparingReview
            await upsertWorkflowDraft(
                stage: .ocrReview,
                parsedInvoice: makeWorkflowPlaceholderInvoice(),
                items: [],
                detail: "\(extraction.lines.count) text line\(extraction.lines.count == 1 ? "" : "s") detected."
            )
            await ensureMinimumProcessingDuration(since: flowStart, minimum: minimumOCRFlowDuration)
            let draftID = activeWorkflowDraftID ?? UUID()
            let nextDraft = OCRReviewDraft(
                draftID: draftID,
                image: previewImage,
                extraction: extraction,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
            cachedOCRReviewDrafts[draftID] = nextDraft
            ocrReviewDraft = nextDraft
        } catch {
            errorMessage = "Could not process the invoice scan."
            await environment.localNotificationService.notify(.scanFailed)
            await upsertWorkflowDraft(
                stage: .failed,
                parsedInvoice: makeWorkflowPlaceholderInvoice(),
                items: [],
                detail: errorMessage
            )
        }

        isProcessing = false
        processingStage = nil
        processingStartedAt = nil
    }

    private nonisolated static func makeCGImage(from image: UIImage) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let cgImage = image.cgImage {
                    continuation.resume(returning: cgImage)
                    return
                }

                let format = UIGraphicsImageRendererFormat.default()
                format.opaque = true
                format.scale = 1
                let size = CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
                let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                continuation.resume(returning: rendered.cgImage)
            }
        }
    }

    private nonisolated static func makePreviewImage(from image: UIImage, maxDimension: CGFloat = 1800) async -> UIImage {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let originalSize = image.size
                guard originalSize.width > 0, originalSize.height > 0 else {
                    continuation.resume(returning: image)
                    return
                }

                let largestSide = max(originalSize.width, originalSize.height)
                guard largestSide > maxDimension else {
                    continuation.resume(returning: image)
                    return
                }

                let scale = maxDimension / largestSide
                let targetSize = CGSize(
                    width: max(1, (originalSize.width * scale).rounded(.down)),
                    height: max(1, (originalSize.height * scale).rounded(.down))
                )

                let format = UIGraphicsImageRendererFormat.default()
                format.opaque = true
                format.scale = 1
                let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: targetSize))
                }
                continuation.resume(returning: rendered)
            }
        }
    }

    private func ensureMinimumProcessingDuration(since start: Date, minimum: TimeInterval) async {
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed < minimum else { return }
        let remaining = minimum - elapsed
        let nanos = UInt64((remaining * 1_000_000_000).rounded())
        try? await Task.sleep(nanoseconds: nanos)
    }

    private func makeWorkflowPlaceholderInvoice() -> ParsedInvoice {
        ParsedInvoice(
            vendorName: nil,
            poNumber: nil,
            invoiceNumber: nil,
            totalCents: nil,
            items: [],
            header: POHeaderFields()
        )
    }

    private func mapPOItems(from parsedItems: [ParsedLineItem]) -> [POItem] {
        parsedItems.map { parsed in
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
    }

    @discardableResult
    private func upsertWorkflowDraft(
        stage: ReviewDraftSnapshot.WorkflowState,
        parsedInvoice: ParsedInvoice,
        items: [POItem],
        detail: String?
    ) async -> ReviewDraftSnapshot? {
        let now = Date()
        let draftID = activeWorkflowDraftID ?? UUID()
        if activeWorkflowDraftID == nil {
            activeWorkflowDraftID = draftID
        }
        let existing = await environment.reviewDraftStore.load(id: draftID)
        let createdAt = existing?.createdAt ?? now

        let snapshot = ReviewDraftSnapshot(
            id: draftID,
            createdAt: createdAt,
            updatedAt: now,
            state: ReviewDraftSnapshot.State(
                parsedInvoice: ReviewDraftSnapshot.ParsedInvoiceSnapshot(invoice: parsedInvoice),
                vendorName: parsedInvoice.vendorName ?? "",
                vendorPhone: "",
                vendorInvoiceNumber: parsedInvoice.invoiceNumber ?? "",
                poReference: parsedInvoice.poNumber ?? "",
                notes: "",
                selectedVendorId: nil,
                orderId: "",
                serviceId: "",
                items: items,
                modeUIRawValue: "quickAdd",
                ignoreTaxOverride: false,
                selectedPOId: nil,
                selectedTicketId: nil,
                workflowStateRawValue: stage.rawValue,
                workflowDetail: detail
            )
        )

        do {
            try await environment.reviewDraftStore.upsert(snapshot)
            inProgressDrafts = await environment.reviewDraftStore.list()
            return snapshot
        } catch {
            return nil
        }
    }

    var processingProgressEstimate: Double {
        processingStage?.progressEstimate ?? 0
    }

    var processingStatusText: String {
        processingStage?.rawValue ?? "Processing intake scan"
    }

    var processingDetailText: String {
        processingStage?.detail ?? "Preparing purchase-order intake result."
    }

    var needsAttentionCount: Int {
        pendingCount + failedCount
    }

    var syncSuccessRate: Double {
        guard todayCount > 0 else { return 0 }
        return min(1, Double(submittedCount) / Double(todayCount))
    }

    private func logScanDiagnostics(
        handoff: ParseHandoffPayload,
        invoice: ParsedInvoice,
        rulesInvoice: ParsedInvoice,
        aiEligible: Bool,
        usedAI: Bool,
        ignoreTaxAndTotals: Bool
    ) {
        #if DEBUG
        let source: String = {
            if usedAI { return "ai+rules" }
            if aiEligible { return "rules-only(ai-failed)" }
            return "rules-only(prequalified)"
        }()
        let confidence = String(format: "%.2f", invoice.confidenceScore)
        let rulesConfidence = String(format: "%.2f", rulesInvoice.confidenceScore)
        let unknownRate = String(format: "%.2f", unknownKindRate(in: invoice) * 100)
        print(
            "[ScanDiag] source=\(source) localOnly=true ignoreTax=\(ignoreTaxAndTotals) confidence=\(confidence) rulesConfidence=\(rulesConfidence) items=\(invoice.items.count) unknownRate=\(unknownRate)%"
        )
        print(
            "[ScanDiag][Handoff] rawLines=\(handoff.metrics.rawLineCount) dedupedLines=\(handoff.metrics.deduplicatedLineCount) rulesLines=\(handoff.metrics.ruleLineCount) modelLines=\(handoff.metrics.modelLineCount) rawChars=\(handoff.metrics.rawCharacterCount) rulesChars=\(handoff.metrics.rulesCharacterCount) modelChars=\(handoff.metrics.modelCharacterCount) rulesTrimmed=\(handoff.metrics.rulesTrimmed) modelTrimmed=\(handoff.metrics.modelTrimmed) barcodes=\(handoff.metrics.barcodeCount)"
        )
        print(
            "[ScanDiag] header vendor='\(invoice.vendorName ?? "")' invoice='\(invoice.invoiceNumber ?? "")' po='\(invoice.poNumber ?? "")' totalCents=\(invoice.totalCents ?? 0)"
        )

        for (index, item) in invoice.items.enumerated() {
            let kindConfidence = String(format: "%.2f", item.kindConfidence)
            let reasonText = item.kindReasons.joined(separator: " | ")
            print(
                "[ScanDiag][Item \(index + 1)] kind=\(item.kind.rawValue) kindConfidence=\(kindConfidence) qty=\(item.quantity ?? 1) costCents=\(item.costCents ?? 0) part='\(item.partNumber ?? "")' name='\(item.name)' reasons='\(reasonText)'"
            )
        }
        #endif
    }

    private func shouldRunOnDeviceAI(rulesInvoice: ParsedInvoice, handoff: ParseHandoffPayload) -> Bool {
        guard environment.foundationModelService.isOnDeviceModelAvailable else {
            return false
        }
        guard handoff.hasModelInput else {
            return false
        }
        guard !rulesInvoice.items.isEmpty else {
            return true
        }

        let rulesUnknownRate = unknownKindRate(in: rulesInvoice)
        let rulesIsStrong = rulesInvoice.confidenceScore >= 0.80 && rulesUnknownRate <= 0.12
        if rulesIsStrong && rulesInvoice.items.count >= 3 {
            return false
        }

        return true
    }

    private func mergedParsedInvoice(aiInvoice: ParsedInvoice?, rulesInvoice: ParsedInvoice) -> ParsedInvoice {
        guard var ai = aiInvoice else {
            return rulesInvoice
        }

        if ai.items.isEmpty {
            ai.items = rulesInvoice.items
        } else if !rulesInvoice.items.isEmpty {
            let aiUnknownRate = unknownKindRate(in: ai)
            let rulesUnknownRate = unknownKindRate(in: rulesInvoice)
            let aiItemFloor = max(1, Int((Double(rulesInvoice.items.count) * 0.55).rounded(.up)))

            if ai.items.count < aiItemFloor || aiUnknownRate > rulesUnknownRate + 0.25 {
                ai.items = rulesInvoice.items
            }
        }

        ai.vendorName = preferred(ai.vendorName, fallback: rulesInvoice.vendorName)
        ai.invoiceNumber = preferred(ai.invoiceNumber, fallback: rulesInvoice.invoiceNumber)
        ai.poNumber = preferred(ai.poNumber, fallback: rulesInvoice.poNumber)

        if ai.totalCents == nil || ai.totalCents == 0 {
            ai.totalCents = rulesInvoice.totalCents ?? computedTotalCents(from: ai.items)
        }

        ai.header.vendorName = preferred(nonEmpty(ai.header.vendorName), fallback: nonEmpty(rulesInvoice.header.vendorName)) ?? ""
        ai.header.vendorInvoiceNumber = preferred(nonEmpty(ai.header.vendorInvoiceNumber), fallback: nonEmpty(rulesInvoice.header.vendorInvoiceNumber)) ?? ""
        ai.header.poReference = preferred(nonEmpty(ai.header.poReference), fallback: nonEmpty(rulesInvoice.header.poReference)) ?? ""
        ai.header.workOrderId = preferred(nonEmpty(ai.header.workOrderId), fallback: nonEmpty(rulesInvoice.header.workOrderId)) ?? ""
        ai.header.serviceId = preferred(nonEmpty(ai.header.serviceId), fallback: nonEmpty(rulesInvoice.header.serviceId)) ?? ""
        ai.header.terms = preferred(nonEmpty(ai.header.terms), fallback: nonEmpty(rulesInvoice.header.terms)) ?? ""
        ai.header.notes = preferred(nonEmpty(ai.header.notes), fallback: nonEmpty(rulesInvoice.header.notes)) ?? ""

        return ai
    }

    private func unknownKindRate(in invoice: ParsedInvoice) -> Double {
        guard !invoice.items.isEmpty else { return 1.0 }
        let unknownCount = invoice.items.filter { $0.kind == .unknown }.count
        return Double(unknownCount) / Double(invoice.items.count)
    }

    private func computedTotalCents(from items: [ParsedLineItem]) -> Int? {
        let total = items.reduce(0) { partial, item in
            partial + ((item.costCents ?? 0) * max(1, item.quantity ?? 1))
        }
        return total > 0 ? total : nil
    }

    private func preferred(_ primary: String?, fallback: String?) -> String? {
        nonEmpty(primary) ?? nonEmpty(fallback)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func loadTodayMetrics() {
        if todayMetricsTask != nil {
            Self.logger.debug("Cancelling previous today-metrics task before reloading.")
        }
        todayMetricsTask?.cancel()
        let dataController = environment.dataController

        todayMetricsTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            Self.logger.debug("Loading dashboard metrics for today.")
            await dataController.waitUntilLoaded()
            guard !Task.isCancelled else {
                Self.logger.debug("Today-metrics task cancelled before Core Data fetch.")
                return
            }
            let container = dataController.container
            let context = container.newBackgroundContext()
            let hasPurchaseOrderEntity = NSEntityDescription.entity(forEntityName: "PurchaseOrder", in: context) != nil
            guard hasPurchaseOrderEntity else {
                Self.logger.error("PurchaseOrder entity missing while loading dashboard metrics.")
                todayCount = 0
                todayTotal = 0
                pendingCount = 0
                submittedCount = 0
                failedCount = 0
                mostRecentSummary = nil
                return
            }
            
            let metrics = await context.perform { () -> (
                count: Int,
                pending: Int,
                submitted: Int,
                failed: Int,
                total: Decimal,
                recent: RecentSummary?
            ) in
                let startOfDay = Calendar.current.startOfDay(for: Date())

                let request: NSFetchRequest<PurchaseOrder> = PurchaseOrder.fetchRequest()
                request.predicate = NSPredicate(format: "date >= %@", startOfDay as NSDate)
                request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

                let results = (try? context.fetch(request)) ?? []
                var count = 0
                var pending = 0
                var submitted = 0
                var failed = 0
                var total = Decimal.zero
                var mostRecentTrackedOrder: PurchaseOrder?

                for order in results {
                    let statusBucket = PurchaseOrderStatusBucket(rawStatus: order.status)
                    guard statusBucket.countsAsTrackedScan else {
                        continue
                    }

                    switch statusBucket {
                    case .submitted:
                        count += 1
                        submitted += 1
                        total += Decimal(order.totalAmount)
                        if mostRecentTrackedOrder == nil {
                            mostRecentTrackedOrder = order
                        }
                    case .pending:
                        count += 1
                        pending += 1
                        total += Decimal(order.totalAmount)
                        if mostRecentTrackedOrder == nil {
                            mostRecentTrackedOrder = order
                        }
                    case .failed:
                        count += 1
                        failed += 1
                        total += Decimal(order.totalAmount)
                        if mostRecentTrackedOrder == nil {
                            mostRecentTrackedOrder = order
                        }
                    case .ignored:
                        break
                    }
                }

                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .medium
                dateFormatter.timeStyle = .short

                let currencyFormatter = NumberFormatter()
                currencyFormatter.numberStyle = .currency
                currencyFormatter.minimumFractionDigits = 2
                currencyFormatter.maximumFractionDigits = 2

                let recent = mostRecentTrackedOrder.map { order in
                    let vendor = order.vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Unknown Vendor"
                        : order.vendorName
                    let totalText = currencyFormatter.string(from: NSNumber(value: order.totalAmount)) ?? "$0.00"
                    let dateText = dateFormatter.string(from: order.date)
                    return RecentSummary(vendor: vendor, total: totalText, date: dateText)
                }

                return (count, pending, submitted, failed, total, recent)
            }

            guard !Task.isCancelled else {
                Self.logger.debug("Today-metrics task cancelled after Core Data fetch.")
                return
            }
            todayCount = metrics.count
            todayTotal = metrics.total
            pendingCount = metrics.pending
            submittedCount = metrics.submitted
            failedCount = metrics.failed
            mostRecentSummary = metrics.recent
            Self.logger.debug(
                "Loaded today metrics scans=\(metrics.count, privacy: .public) submitted=\(metrics.submitted, privacy: .public) pending=\(metrics.pending, privacy: .public) failed=\(metrics.failed, privacy: .public)."
            )
            PartsIntakeWidgetBridge.publish(
                scansToday: metrics.count,
                submittedCount: metrics.submitted,
                failedCount: metrics.failed,
                pendingCount: metrics.pending,
                totalValue: metrics.total
            )
        }
    }

    var todayTotalFormatted: String {
        let number = NSDecimalNumber(decimal: todayTotal)
        return Self.currencyFormatter.string(from: number) ?? "0.00"
    }

    var todayAverageFormatted: String {
        guard todayCount > 0 else { return "$0.00" }
        let total = NSDecimalNumber(decimal: todayTotal)
        let count = NSDecimalNumber(value: todayCount)
        let average = total.dividing(by: count)
        return Self.currencyFormatter.string(from: average) ?? "$0.00"
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let uiTestReviewInvoice: ParsedInvoice = {
        ParsedInvoice(
            vendorName: "METRO AUTO PARTS SUPPLY",
            poNumber: "PO-99012",
            invoiceNumber: "MAP-45821",
            totalCents: 164_212,
            items: [
                ParsedLineItem(
                    name: "Front Brake Pad Set - Ceramic",
                    quantity: 6,
                    costCents: 6_800,
                    partNumber: "ACD-41-993",
                    confidence: 0.95,
                    kind: .part,
                    kindConfidence: 0.90,
                    kindReasons: ["ui test fixture"]
                ),
                ParsedLineItem(
                    name: "225/60/16 Primacy Michelin",
                    quantity: 4,
                    costCents: 18_000,
                    partNumber: "MICH-123",
                    confidence: 0.95,
                    kind: .tire,
                    kindConfidence: 0.90,
                    kindReasons: ["ui test fixture"]
                ),
                ParsedLineItem(
                    name: "Shipping",
                    quantity: 1,
                    costCents: 4_500,
                    partNumber: nil,
                    confidence: 0.90,
                    kind: .fee,
                    kindConfidence: 0.85,
                    kindReasons: ["ui test fixture"]
                )
            ],
            header: POHeaderFields(
                vendorName: "METRO AUTO PARTS SUPPLY",
                vendorInvoiceNumber: "MAP-45821",
                poReference: "PO-99012",
                workOrderId: "",
                serviceId: "",
                terms: "",
                notes: ""
            )
        )
    }()
}

private extension CGImagePropertyOrientation {
    var uiImageOrientation: UIImage.Orientation {
        switch self {
        case .up:
            return .up
        case .down:
            return .down
        case .left:
            return .left
        case .right:
            return .right
        case .upMirrored:
            return .upMirrored
        case .downMirrored:
            return .downMirrored
        case .leftMirrored:
            return .leftMirrored
        case .rightMirrored:
            return .rightMirrored
        @unknown default:
            return .up
        }
    }
}
