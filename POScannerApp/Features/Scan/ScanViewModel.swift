//
//  ScanViewModel.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreParsing
import Combine
import CoreGraphics
import CoreData
import ImageIO
import UIKit
import os
@preconcurrency import Vision

@MainActor
final class ScanViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.Scan")
    private nonisolated static let fallbackRenderableImage: UIImage = {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }()

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
                return 0.78
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
    @Published var draftCount: Int = 0
    @Published var reviewQueueCount: Int = 0
    @Published var mostRecentSummary: RecentSummary?
    @Published var inProgressDrafts: [ReviewDraftSnapshot] = []
    @Published private(set) var isLoadingTodayMetrics: Bool = false
    @Published private(set) var isLoadingInProgressDrafts: Bool = false
    @Published private(set) var lastDashboardRefreshAt: Date?
    @Published private(set) var lastDraftRefreshAt: Date?

    private let minimumOCRFlowDuration: TimeInterval = 1.20
    private let minimumParseFlowDuration: TimeInterval = 1.80
    private let preferredDraftDefaultsKey = "liveActivityPreferredDraftID"
    private var activeWorkflowDraftID: UUID?
    private var captureFlowSessionPending: Bool = false
    private var cachedOCRReviewDrafts: [UUID: OCRReviewDraft] = [:]
    private var todayMetricsTask: Task<Void, Never>?
    private var pendingTodayMetricsReload: Bool = false
    private var lastTodayMetricsLoadAt: Date?
    private var inProgressDraftsTask: Task<Void, Never>?
    private var pendingInProgressDraftsReload: Bool = false
    private var lastInProgressDraftsLoadAt: Date?
    private let minimumTodayMetricsReloadInterval: TimeInterval = 2.5
    private let minimumInProgressDraftsReloadInterval: TimeInterval = 2.5

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    deinit {
        todayMetricsTask?.cancel()
        inProgressDraftsTask?.cancel()
    }

    func handleScannedImage(
        _ image: UIImage,
        orientation: CGImagePropertyOrientation,
        ignoreTaxAndTotals: Bool
    ) {
        guard !isProcessing else {
            Self.logger.debug("Ignoring scanned image because workflow is already processing.")
            return
        }
        Self.logger.debug("Scanned image accepted for OCR pipeline. ignoreTax=\(ignoreTaxAndTotals, privacy: .public)")
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
        guard ocrReviewDraft != nil else { return }
        ocrReviewDraft = nil
        Self.logger.debug("OCR review cancelled.")
    }

    func continueFromOCRReview(editedText: String, includeDetectedBarcodes: Bool) {
        guard !isProcessing else { return }
        guard let draft = ocrReviewDraft else { return }
        Self.logger.debug(
            "Continuing from OCR review. draftID=\(draft.draftID.uuidString, privacy: .public) includeBarcodes=\(includeDetectedBarcodes, privacy: .public)"
        )
        activeWorkflowDraftID = draft.draftID
        captureFlowSessionPending = false
        setPreferredLiveActivityDraftID(draft.draftID)
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

    func prepareForNewCaptureSession() {
        guard !isProcessing else { return }
        if let activeWorkflowDraftID {
            Self.logger.debug("Preparing new capture session. Clearing active workflow draft \(activeWorkflowDraftID.uuidString, privacy: .public).")
        } else {
            Self.logger.debug("Preparing new capture session.")
        }
        captureFlowSessionPending = true
        activeWorkflowDraftID = nil
        clearPreferredLiveActivityDraftID()
    }

    func markCaptureFlowSessionPending(_ pending: Bool) {
        guard captureFlowSessionPending != pending else { return }
        captureFlowSessionPending = pending
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
        Self.logger.debug("Capture workflow stage -> parsing.")
        let parsingStageStart = Date()

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
        await ensureMinimumStageDuration(since: parsingStageStart, stage: .parsing)
        processingStage = .finalizing
        Self.logger.debug("Capture workflow stage -> finalizing.")
        let finalizingStageStart = Date()
        logScanDiagnostics(
            handoff: handoff,
            invoice: invoice,
            rulesInvoice: rulesInvoice,
            aiEligible: aiEligible,
            usedAI: ai != nil,
            ignoreTaxAndTotals: ignoreTaxAndTotals
        )
        await ensureMinimumStageDuration(since: finalizingStageStart, stage: .finalizing)
        await ensureMinimumProcessingDuration(
            since: flowStart,
            minimum: adjustedJourneyDuration(minimumParseFlowDuration)
        )
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
        if let draftID = draftSnapshot?.id {
            Self.logger.debug("Capture workflow opened review route. draftID=\(draftID.uuidString, privacy: .public)")
        } else {
            Self.logger.debug("Capture workflow opened review route without persisted draft snapshot.")
        }
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
        Self.logger.debug("Capture workflow parse/finalize completed.")
    }

    private nonisolated static func computeRulesInvoice(
        reviewedText: String,
        barcodeHints: [OCRService.DetectedBarcode],
        ignoreTaxAndTotals: Bool,
        handoffService: LocalParseHandoffService,
        parser: POParser
    ) async -> (ParseHandoffPayload, ParsedInvoice) {
        await Task.detached(priority: .userInitiated) {
            let handoff = handoffService.build(
                reviewedText: reviewedText,
                barcodeHints: barcodeHints
            )
            let rulesInvoice = parser.parse(
                from: handoff.rulesInputText,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
            return (handoff, rulesInvoice)
        }.value
    }

    var uiTestReviewFixtureEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-test-review-fixture")
    }

    func openUITestReviewFixture() {
        guard uiTestReviewFixtureEnabled else { return }
        parsedInvoiceRoute = ParsedInvoiceRoute(invoice: Self.uiTestReviewInvoice, draftSnapshot: nil)
    }

    func loadInProgressDrafts(force: Bool = false) {
        if inProgressDraftsTask != nil {
            if force && !pendingInProgressDraftsReload {
                pendingInProgressDraftsReload = true
            }
            return
        }
        if !force,
           let lastInProgressDraftsLoadAt,
           Date().timeIntervalSince(lastInProgressDraftsLoadAt) < minimumInProgressDraftsReloadInterval {
            return
        }
        inProgressDraftsTask = Task { [weak self] in
            guard let self else { return }
            isLoadingInProgressDrafts = true
            defer {
                isLoadingInProgressDrafts = false
                inProgressDraftsTask = nil
                if pendingInProgressDraftsReload {
                    pendingInProgressDraftsReload = false
                    loadInProgressDrafts(force: true)
                }
            }
            let drafts = await environment.reviewDraftStore.list()
            guard !Task.isCancelled else {
                return
            }
            lastInProgressDraftsLoadAt = Date()
            lastDraftRefreshAt = lastInProgressDraftsLoadAt
            if inProgressDrafts != drafts {
                inProgressDrafts = drafts
            }
            refreshDraftMetrics(from: drafts)
            reconcileActiveWorkflowDraft(with: drafts)
        }
    }

    var latestDraft: ReviewDraftSnapshot? {
        inProgressDrafts.first
    }

    var activeWorkflowDraftIDForLiveActivity: UUID? {
        activeWorkflowDraftID
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
        captureFlowSessionPending = false
        setPreferredLiveActivityDraftID(draft.id)
        parsedInvoiceRoute = nil
        ocrReviewDraft = cached
    }

    func resumeDraft(_ draft: ReviewDraftSnapshot) {
        activeWorkflowDraftID = draft.id
        captureFlowSessionPending = false
        setPreferredLiveActivityDraftID(draft.id)
        parsedInvoiceRoute = ParsedInvoiceRoute(invoice: draft.state.parsedInvoice.parsedInvoice, draftSnapshot: draft)
    }

    @discardableResult
    func resumeDraft(id: UUID) async -> Bool {
        if parsedInvoiceRoute?.draftSnapshot?.id == id || ocrReviewDraft?.draftID == id {
            activeWorkflowDraftID = id
            captureFlowSessionPending = false
            setPreferredLiveActivityDraftID(id)
            return true
        }
        guard let draft = await environment.reviewDraftStore.load(id: id) else { return false }
        switch draft.workflowState {
        case .ocrReview:
            guard canResumeOCRReview(draft) else { return false }
            resumeOCRReview(draft)
            return true
        case .scanning, .parsing:
            if isProcessing, activeWorkflowDraftID == id {
                setPreferredLiveActivityDraftID(id)
                return true
            }
            return false
        case .reviewReady, .reviewEdited, .submitting, .failed:
            break
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
                clearPreferredLiveActivityDraftIDIfMatches(draft.id)
                cachedOCRReviewDrafts[draft.id] = nil
                let drafts = await environment.reviewDraftStore.list()
                lastInProgressDraftsLoadAt = Date()
                lastDraftRefreshAt = lastInProgressDraftsLoadAt
                inProgressDrafts = drafts
                refreshDraftMetrics(from: drafts)
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
        _ = orientation
        captureFlowSessionPending = false
        activeWorkflowDraftID = UUID()
        if let activeWorkflowDraftID {
            setPreferredLiveActivityDraftID(activeWorkflowDraftID)
            Self.logger.debug("Capture workflow started. draftID=\(activeWorkflowDraftID.uuidString, privacy: .public)")
        }
        isProcessing = true
        errorMessage = nil
        let flowStart = Date()
        processingStartedAt = flowStart
        processingStage = .extractingText
        Self.logger.debug("Capture workflow stage -> extractingText.")
        let extractionStageStart = Date()
        await upsertWorkflowDraft(
            stage: .scanning,
            parsedInvoice: makeWorkflowPlaceholderInvoice(),
            items: [],
            detail: "Running OCR on captured invoice."
        )

        do {
            let preparedImage = await Self.prepareCaptureImageForOCR(image)
            let previewImage = await Self.makePreviewImage(from: preparedImage)
            guard let cgImage = await Self.makeCGImage(from: preparedImage) else {
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
            let effectiveOrientation = preparedImage.imageOrientation.cgImagePropertyOrientation
            let extraction = try await environment.ocrService.extractDocument(
                from: cgImage,
                orientation: effectiveOrientation
            )
            Self.logger.debug(
                "Capture workflow OCR extracted lines=\(extraction.lines.count, privacy: .public) barcodes=\(extraction.barcodes.count, privacy: .public)."
            )
            AppHaptics.success()
            await ensureMinimumStageDuration(since: extractionStageStart, stage: .extractingText)
            processingStage = .preparingReview
            Self.logger.debug("Capture workflow stage -> preparingReview.")
            let preparingStageStart = Date()
            await upsertWorkflowDraft(
                stage: .ocrReview,
                parsedInvoice: makeWorkflowPlaceholderInvoice(),
                items: [],
                detail: "\(extraction.lines.count) text line\(extraction.lines.count == 1 ? "" : "s") detected."
            )
            await ensureMinimumStageDuration(since: preparingStageStart, stage: .preparingReview)
            await ensureMinimumProcessingDuration(
                since: flowStart,
                minimum: adjustedJourneyDuration(minimumOCRFlowDuration)
            )
            let draftID = activeWorkflowDraftID ?? UUID()
            let nextDraft = OCRReviewDraft(
                draftID: draftID,
                image: previewImage,
                extraction: extraction,
                ignoreTaxAndTotals: ignoreTaxAndTotals
            )
            cachedOCRReviewDrafts[draftID] = nextDraft
            ocrReviewDraft = nextDraft
            Self.logger.debug("Capture workflow moved to OCR review. draftID=\(draftID.uuidString, privacy: .public)")
        } catch {
            errorMessage = "Could not process the invoice scan."
            Self.logger.error("Capture workflow failed while processing scanned image.")
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
        Self.logger.debug("Capture workflow stopped.")
    }

    private nonisolated static func makeCGImage(from image: UIImage) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            if let cgImage = image.cgImage {
                return cgImage
            }

            guard let size = sanitizedRenderableSize(from: image.size) else {
                return fallbackRenderableImage.cgImage
            }
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            return rendered.cgImage
        }.value
    }

    private nonisolated static func prepareCaptureImageForOCR(_ image: UIImage) async -> UIImage {
        await Task.detached(priority: .userInitiated) {
            let normalized = normalizedUprightImage(from: image)
            return cropToLikelyDocument(from: normalized) ?? normalized
        }.value
    }

    private nonisolated static func normalizedUprightImage(from image: UIImage) -> UIImage {
        guard let size = sanitizedRenderableSize(from: image.size) else {
            return fallbackRenderableImage
        }
        guard image.imageOrientation != .up || image.cgImage == nil else {
            return image
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = image.scale > 0 ? image.scale : 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private nonisolated static func cropToLikelyDocument(from image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width.isFinite, height.isFinite, width > 10, height > 10 else { return nil }

        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.25
        request.minimumSize = 0.45
        request.quadratureTolerance = 35
        request.regionOfInterest = CGRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92)

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first else { return nil }
        let normalized = observation.boundingBox.standardized
        guard normalized.width.isFinite,
              normalized.height.isFinite,
              normalized.width > 0,
              normalized.height > 0 else {
            return nil
        }

        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let cropRect = CGRect(
            x: normalized.minX * width,
            y: (1 - normalized.maxY) * height,
            width: normalized.width * width,
            height: normalized.height * height
        )
        .integral
        .intersection(imageBounds)

        guard cropRect.width.isFinite,
              cropRect.height.isFinite,
              cropRect.width > (width * 0.55),
              cropRect.height > (height * 0.55) else {
            return nil
        }

        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale > 0 ? image.scale : 1, orientation: .up)
    }

    private nonisolated static func makePreviewImage(from image: UIImage, maxDimension: CGFloat = 1800) async -> UIImage {
        await Task.detached(priority: .userInitiated) {
            guard let originalSize = sanitizedRenderableSize(from: image.size) else {
                return fallbackRenderableImage
            }

            let largestSide = max(originalSize.width, originalSize.height)
            guard largestSide.isFinite, largestSide > maxDimension else {
                return image
            }

            let scale = maxDimension / largestSide
            guard scale.isFinite, scale > 0 else { return image }
            guard let targetSize = sanitizedRenderableSize(
                from: CGSize(
                    width: originalSize.width * scale,
                    height: originalSize.height * scale
                )
            ) else {
                return image
            }

            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            format.scale = 1
            return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }.value
    }

    private nonisolated static func sanitizedRenderableSize(from size: CGSize) -> CGSize? {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        let width = max(1, size.width.rounded(.towardZero))
        let height = max(1, size.height.rounded(.towardZero))
        guard width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    private func ensureMinimumProcessingDuration(since start: Date, minimum: TimeInterval) async {
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed < minimum else { return }
        let remaining = minimum - elapsed
        let nanos = UInt64((remaining * 1_000_000_000).rounded())
        try? await Task.sleep(nanoseconds: nanos)
    }

    private func ensureMinimumStageDuration(since start: Date, stage: ProcessingStage) async {
        await ensureMinimumProcessingDuration(
            since: start,
            minimum: adjustedJourneyDuration(minimumStageDuration(for: stage))
        )
    }

    private func minimumStageDuration(for stage: ProcessingStage) -> TimeInterval {
        switch stage {
        case .extractingText:
            return 0.35
        case .preparingReview:
            return 0.55
        case .parsing:
            return 0.70
        case .finalizing:
            return 0.40
        }
    }

    private func adjustedJourneyDuration(_ duration: TimeInterval) -> TimeInterval {
        #if canImport(UIKit)
        let scale: Double = UIAccessibility.isReduceMotionEnabled ? 0.7 : 1.0
        return duration * scale
        #else
        return duration
        #endif
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
        let forceIgnoreTax = ignoreTaxAndTotalsSetting
        return parsedItems.map { parsed in
            let cents = parsed.costCents ?? 0
            let normalizedSKU = parsed.partNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return POItem(
                description: parsed.name,
                sku: normalizedSKU,
                quantity: Double(max(1, parsed.quantity ?? 1)),
                unitCost: cents > 0 ? (Decimal(cents) / 100) : 0,
                isTaxable: !forceIgnoreTax,
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
        if let existing,
           existing.state.workflowStateRawValue != nil,
           !existing.workflowState.allowsTransition(to: stage) {
            Self.logger.debug(
                "Ignoring workflow draft stage regression from \(existing.workflowState.rawValue, privacy: .public) to \(stage.rawValue, privacy: .public)."
            )
            return existing
        }
        let createdAt = existing?.createdAt ?? now

        let snapshot = ReviewDraftSnapshot(
            id: draftID,
            createdAt: createdAt,
            updatedAt: now,
            state: ReviewDraftSnapshot.State(
                parsedInvoice: ReviewDraftSnapshot.ParsedInvoiceSnapshot(invoice: parsedInvoice),
                vendorName: parsedInvoice.vendorName ?? "",
                vendorPhone: parsedInvoice.header.vendorPhone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                vendorEmail: {
                    let trimmed = parsedInvoice.header.vendorEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (trimmed?.isEmpty == false) ? trimmed : nil
                }(),
                vendorInvoiceNumber: parsedInvoice.invoiceNumber ?? "",
                poReference: parsedInvoice.poNumber ?? "",
                notes: "",
                selectedVendorId: nil,
                orderId: "",
                serviceId: "",
                items: items,
                modeUIRawValue: "quickAdd",
                ignoreTaxOverride: ignoreTaxAndTotalsSetting,
                selectedPOId: nil,
                selectedTicketId: nil,
                workflowStateRawValue: stage.rawValue,
                workflowDetail: detail
            )
        )

        do {
            try await environment.reviewDraftStore.upsert(snapshot)
            Self.logger.debug(
                "Workflow draft upserted. draftID=\(draftID.uuidString, privacy: .public) stage=\(stage.rawValue, privacy: .public)"
            )
            let drafts = await environment.reviewDraftStore.list()
            lastInProgressDraftsLoadAt = now
            lastDraftRefreshAt = now
            if inProgressDrafts != drafts {
                inProgressDrafts = drafts
            }
            refreshDraftMetrics(from: drafts)
            reconcileActiveWorkflowDraft(with: drafts)
            return snapshot
        } catch {
            Self.logger.error(
                "Workflow draft upsert failed. draftID=\(draftID.uuidString, privacy: .public) stage=\(stage.rawValue, privacy: .public)"
            )
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

    var isRefreshingAnyDashboardData: Bool {
        isLoadingTodayMetrics || isLoadingInProgressDrafts
    }

    var refreshStatusText: String {
        switch (isLoadingTodayMetrics, isLoadingInProgressDrafts) {
        case (true, true):
            return "Refreshing drafts and dashboard metrics"
        case (true, false):
            return "Refreshing dashboard metrics"
        case (false, true):
            return "Refreshing in-progress drafts"
        case (false, false):
            return "Dashboard is up to date"
        }
    }

    var refreshDetailText: String {
        switch (isLoadingTodayMetrics, isLoadingInProgressDrafts) {
        case (true, true):
            return "Syncing local draft state and Shopmonkey dashboard totals."
        case (true, false):
            return "Recomputing today's scans, submissions, and sync status."
        case (false, true):
            return "Loading current draft queue and workflow states."
        case (false, false):
            return "All intake metrics and drafts are current."
        }
    }

    var needsAttentionCount: Int {
        pendingCount + failedCount
    }

    var syncSuccessRate: Double {
        guard todayCount > 0 else { return 0 }
        let rate = Double(submittedCount) / Double(todayCount)
        guard rate.isFinite else { return 0 }
        return min(1, max(0, rate))
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
        ai.header.vendorPhone = preferred(nonEmpty(ai.header.vendorPhone), fallback: nonEmpty(rulesInvoice.header.vendorPhone))
        ai.header.vendorEmail = preferred(nonEmpty(ai.header.vendorEmail), fallback: nonEmpty(rulesInvoice.header.vendorEmail))
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

    @discardableResult
    func performScheduledInventorySync(
        trigger: InventorySyncTrigger,
        force: Bool = false
    ) async -> InventorySyncRunResult {
        let coordinator = environment.inventorySyncCoordinator
        let orderRepository = environment.orderRepository
        let now = environment.dateProvider.now

        return await coordinator.runScheduledPull(
            trigger: trigger,
            now: now,
            force: force
        ) { _ in
            let orders = try await orderRepository.fetchOrders()
            return InventorySyncPullPayload(orders: orders)
        }
    }

    func performManualDashboardRefresh() async {
        _ = await performScheduledInventorySync(trigger: .manual, force: true)
        loadInProgressDrafts(force: true)
        loadTodayMetrics(force: true)
        await waitForDashboardLoadsToSettle(timeout: 2.4)
    }

    private func waitForDashboardLoadsToSettle(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if todayMetricsTask == nil,
               inProgressDraftsTask == nil,
               !isLoadingTodayMetrics,
               !isLoadingInProgressDrafts {
                return
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    func loadTodayMetrics(force: Bool = false) {
        if todayMetricsTask != nil {
            if force && !pendingTodayMetricsReload {
                pendingTodayMetricsReload = true
            }
            return
        }
        if !force,
           let lastTodayMetricsLoadAt,
           Date().timeIntervalSince(lastTodayMetricsLoadAt) < minimumTodayMetricsReloadInterval {
            return
        }
        let dataController = environment.dataController

        todayMetricsTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            isLoadingTodayMetrics = true
            defer {
                isLoadingTodayMetrics = false
                todayMetricsTask = nil
                if pendingTodayMetricsReload {
                    pendingTodayMetricsReload = false
                    loadTodayMetrics(force: true)
                }
            }
            await dataController.waitUntilLoaded()
            guard !Task.isCancelled else {
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
                publishWidgetSnapshot()
                mostRecentSummary = nil
                lastDashboardRefreshAt = Date()
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
                var mostRecentSubmittedOrder: PurchaseOrder?
                var mostRecentTrackedOrder: PurchaseOrder?

                for order in results {
                    let statusBucket = PurchaseOrderStatusBucket.from(order)
                    guard statusBucket.countsAsTrackedScan else {
                        continue
                    }

                    switch statusBucket {
                    case .submitted:
                        count += 1
                        submitted += 1
                        total += Decimal(order.totalAmount)
                        if mostRecentSubmittedOrder == nil {
                            mostRecentSubmittedOrder = order
                        }
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
                let preferredRecent = (mostRecentSubmittedOrder ?? mostRecentTrackedOrder).map { order in
                    let vendor = order.vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Unknown Vendor"
                        : order.vendorName
                    let totalText = currencyFormatter.string(from: NSNumber(value: order.totalAmount)) ?? "$0.00"
                    let dateText = dateFormatter.string(from: order.date)
                    return RecentSummary(vendor: vendor, total: totalText, date: dateText)
                }

                return (count, pending, submitted, failed, total, preferredRecent ?? recent)
            }

            guard !Task.isCancelled else {
                return
            }
            todayCount = metrics.count
            todayTotal = metrics.total
            pendingCount = metrics.pending
            submittedCount = metrics.submitted
            failedCount = metrics.failed
            mostRecentSummary = metrics.recent
            lastTodayMetricsLoadAt = Date()
            lastDashboardRefreshAt = lastTodayMetricsLoadAt
            publishWidgetSnapshot()
        }
    }

    private func refreshDraftMetrics(from drafts: [ReviewDraftSnapshot]) {
        draftCount = drafts.count
        reviewQueueCount = drafts.filter {
            switch $0.workflowState {
            case .reviewReady, .reviewEdited, .failed:
                return true
            case .scanning, .ocrReview, .parsing, .submitting:
                return false
            }
        }.count
        publishWidgetSnapshot()
    }

    private func publishWidgetSnapshot() {
        PartsIntakeWidgetBridge.publish(
            scansToday: todayCount,
            submittedCount: submittedCount,
            failedCount: failedCount,
            pendingCount: pendingCount,
            draftCount: draftCount,
            reviewCount: reviewQueueCount,
            totalValue: todayTotal
        )
    }

    private func reconcileActiveWorkflowDraft(with drafts: [ReviewDraftSnapshot]) {
        if drafts.isEmpty {
            activeWorkflowDraftID = nil
            clearPreferredLiveActivityDraftID()
            return
        }

        if let preferredDraftID = preferredLiveActivityDraftID(),
           !drafts.contains(where: { $0.id == preferredDraftID }) {
            clearPreferredLiveActivityDraftID()
        }

        if activeWorkflowDraftID == nil, !isProcessing, !captureFlowSessionPending {
            if let preferredDraftID = preferredLiveActivityDraftID(),
               let preferredDraft = drafts.first(where: { $0.id == preferredDraftID }),
               isStoredDraftEligibleForLiveActivity(preferredDraft) {
                activeWorkflowDraftID = preferredDraftID
                return
            }

            if let newestInFlightDraft = drafts
                .filter({ isStoredDraftEligibleForLiveActivity($0) })
                .sorted(by: { lhs, rhs in
                    if lhs.updatedAt == rhs.updatedAt {
                        return workflowLiveActivityPriority(lhs.workflowState) > workflowLiveActivityPriority(rhs.workflowState)
                    }
                    return lhs.updatedAt > rhs.updatedAt
                })
                .first {
                activeWorkflowDraftID = newestInFlightDraft.id
                setPreferredLiveActivityDraftID(newestInFlightDraft.id)
                return
            }
        }

        guard let activeWorkflowDraftID else { return }
        if drafts.contains(where: { $0.id == activeWorkflowDraftID }) {
            return
        }
        if parsedInvoiceRoute?.draftSnapshot?.id == activeWorkflowDraftID {
            return
        }
        if ocrReviewDraft?.draftID == activeWorkflowDraftID {
            return
        }
        guard !isProcessing else { return }
        self.activeWorkflowDraftID = nil
        clearPreferredLiveActivityDraftIDIfMatches(activeWorkflowDraftID)
        cachedOCRReviewDrafts[activeWorkflowDraftID] = nil
    }

    private func isStoredDraftEligibleForLiveActivity(_ draft: ReviewDraftSnapshot) -> Bool {
        guard draft.isLiveIntakeSession else { return false }
        if activeWorkflowDraftID == draft.id && isProcessing {
            return true
        }
        if parsedInvoiceRoute?.draftSnapshot?.id == draft.id {
            return true
        }
        if ocrReviewDraft?.draftID == draft.id {
            return true
        }

        switch draft.workflowState {
        case .scanning, .parsing:
            // In-flight scan stages are only resumable while actively processing.
            return false
        case .ocrReview:
            // OCR review requires cached extraction payload for a true resume.
            return canResumeOCRReview(draft)
        case .reviewReady, .reviewEdited, .submitting:
            return Date().timeIntervalSince(draft.updatedAt) <= draft.liveActivityRecencyWindow
        case .failed:
            return false
        }
    }

    private func preferredLiveActivityDraftID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: preferredDraftDefaultsKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private func workflowLiveActivityPriority(_ state: ReviewDraftSnapshot.WorkflowState) -> Int {
        switch state {
        case .submitting:
            return 5
        case .reviewEdited:
            return 4
        case .reviewReady:
            return 3
        case .parsing:
            return 2
        case .ocrReview:
            return 1
        case .scanning:
            return 0
        case .failed:
            return -1
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

    private var ignoreTaxAndTotalsSetting: Bool {
        UserDefaults.standard.bool(forKey: "ignoreTaxAndTotals")
    }

    private func setPreferredLiveActivityDraftID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: preferredDraftDefaultsKey)
    }

    private func clearPreferredLiveActivityDraftIDIfMatches(_ id: UUID) {
        guard let preferredID = preferredLiveActivityDraftID(), preferredID == id else { return }
        clearPreferredLiveActivityDraftID()
    }

    private func clearPreferredLiveActivityDraftID() {
        UserDefaults.standard.removeObject(forKey: preferredDraftDefaultsKey)
    }

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
