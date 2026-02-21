//
//  ScanViewModelDraftResumeTests.swift
//  POScannerAppTests
//

import Foundation
import Testing
@testable import POScannerApp

private func makeScanTestEnvironment(draftFileURL: URL) -> AppEnvironment {
    let dataController = DataController(inMemory: true)
    let keychainService = KeychainService(service: "POScannerApp.scan-tests.\(UUID().uuidString)")
    let secureStorage = SecureStorage(keychainService: keychainService)
    let networkDiagnostics = NetworkDiagnosticsRecorder.shared
    let reviewDraftStore = ReviewDraftStore(fileURL: draftFileURL)
    let localNotificationService = LocalNotificationService()
    let apiClient = APIClient(
        baseURL: ShopmonkeyAPI.baseURL,
        tokenProvider: { throw APIError.missingToken },
        diagnosticsRecorder: networkDiagnostics
    )

    return AppEnvironment(
        dataController: dataController,
        keychainService: keychainService,
        secureStorage: secureStorage,
        networkDiagnostics: networkDiagnostics,
        reviewDraftStore: reviewDraftStore,
        localNotificationService: localNotificationService,
        apiClient: apiClient,
        shopmonkeyAPI: ShopmonkeyAPI(client: apiClient, diagnosticsRecorder: networkDiagnostics),
        ocrService: OCRService(),
        poParser: POParser(),
        foundationModelService: FoundationModelService(),
        parseHandoffService: LocalParseHandoffService(),
        dateProvider: SystemDateProvider()
    )
}

private func makeDraftSnapshot(
    id: UUID = UUID(),
    workflowState: ReviewDraftSnapshot.WorkflowState,
    updatedAt: Date = Date()
) -> ReviewDraftSnapshot {
    let parsedInvoice = ParsedInvoice(
        vendorName: "Advance Auto Parts",
        poNumber: "PO-4455",
        invoiceNumber: "INV-9910",
        totalCents: 18_500,
        items: [
            ParsedLineItem(
                name: "Brake Pad Set",
                quantity: 1,
                costCents: 18_500,
                partNumber: "PAD-9910",
                confidence: 0.9,
                kind: .part,
                kindConfidence: 0.9,
                kindReasons: ["test fixture"]
            )
        ]
    )

    return ReviewDraftSnapshot(
        id: id,
        createdAt: updatedAt.addingTimeInterval(-120),
        updatedAt: updatedAt,
        state: ReviewDraftSnapshot.State(
            parsedInvoice: ReviewDraftSnapshot.ParsedInvoiceSnapshot(invoice: parsedInvoice),
            vendorName: "Advance Auto Parts",
            vendorPhone: "",
            vendorEmail: nil,
            vendorNotes: nil,
            vendorInvoiceNumber: "INV-9910",
            poReference: "PO-4455",
            notes: "",
            selectedVendorId: "vendor_1",
            orderId: "order_1",
            serviceId: "service_1",
            items: [
                POItem(
                    description: "Brake Pad Set",
                    sku: "PAD-9910",
                    quantity: 1,
                    unitCost: Decimal(185),
                    isTaxable: true,
                    partNumber: "PAD-9910",
                    confidence: 0.9,
                    kind: .part,
                    kindConfidence: 0.9,
                    kindReasons: ["test fixture"]
                )
            ],
            modeUIRawValue: "quickAdd",
            ignoreTaxOverride: false,
            selectedPOId: nil,
            selectedTicketId: nil,
            workflowStateRawValue: workflowState.rawValue,
            workflowDetail: "fixture"
        )
    )
}

@Suite("Scan ViewModel Draft Resume")
struct ScanViewModelDraftResumeTests {
    @MainActor
    @Test func resumeDraftRejectsStaleOCRReviewWithoutCachedPayload() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan_resume_ocr_\(UUID().uuidString).json")
        let environment = makeScanTestEnvironment(draftFileURL: fileURL)
        let draft = makeDraftSnapshot(workflowState: .ocrReview)
        try await environment.reviewDraftStore.upsert(draft)

        let viewModel = ScanViewModel(environment: environment)
        let resumed = await viewModel.resumeDraft(id: draft.id)

        #expect(resumed == false)
        #expect(viewModel.parsedInvoiceRoute == nil)
        #expect(viewModel.ocrReviewDraft == nil)
    }

    @MainActor
    @Test func resumeDraftOpensReviewForReviewReadyDraft() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan_resume_ready_\(UUID().uuidString).json")
        let environment = makeScanTestEnvironment(draftFileURL: fileURL)
        let draft = makeDraftSnapshot(workflowState: .reviewReady)
        try await environment.reviewDraftStore.upsert(draft)

        let viewModel = ScanViewModel(environment: environment)
        let resumed = await viewModel.resumeDraft(id: draft.id)

        #expect(resumed == true)
        #expect(viewModel.parsedInvoiceRoute?.draftSnapshot?.id == draft.id)
        #expect(viewModel.activeWorkflowDraftIDForLiveActivity == draft.id)
    }

    @MainActor
    @Test func resumeDraftRejectsStaleScanningDraftWhenNoLiveProcessing() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan_resume_scanning_\(UUID().uuidString).json")
        let environment = makeScanTestEnvironment(draftFileURL: fileURL)
        let draft = makeDraftSnapshot(workflowState: .scanning)
        try await environment.reviewDraftStore.upsert(draft)

        let viewModel = ScanViewModel(environment: environment)
        let resumed = await viewModel.resumeDraft(id: draft.id)

        #expect(resumed == false)
        #expect(viewModel.activeWorkflowDraftIDForLiveActivity == nil)
    }
}

