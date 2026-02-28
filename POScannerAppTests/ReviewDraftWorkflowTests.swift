//
//  ReviewDraftWorkflowTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

struct ReviewDraftWorkflowTests {
    @Test func workflowTransitionPolicyIsMonotonicWithFailureRecovery() {
        #expect(ReviewDraftSnapshot.WorkflowState.scanning.allowsTransition(to: .ocrReview))
        #expect(ReviewDraftSnapshot.WorkflowState.parsing.allowsTransition(to: .reviewReady))
        #expect(ReviewDraftSnapshot.WorkflowState.reviewReady.allowsTransition(to: .reviewEdited))
        #expect(ReviewDraftSnapshot.WorkflowState.reviewEdited.allowsTransition(to: .submitting))
        #expect(ReviewDraftSnapshot.WorkflowState.submitting.allowsTransition(to: .failed))

        #expect(!ReviewDraftSnapshot.WorkflowState.submitting.allowsTransition(to: .reviewEdited))
        #expect(!ReviewDraftSnapshot.WorkflowState.reviewReady.allowsTransition(to: .parsing))

        #expect(ReviewDraftSnapshot.WorkflowState.failed.allowsTransition(to: .reviewEdited))
        #expect(ReviewDraftSnapshot.WorkflowState.failed.allowsTransition(to: .reviewReady))
        #expect(!ReviewDraftSnapshot.WorkflowState.failed.allowsTransition(to: .scanning))
    }

    @Test func draftStoreRejectsWorkflowRegressionUpdate() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-draft-store-regression-\(UUID().uuidString).json")
        let store = ReviewDraftStore(fileURL: fileURL)
        let draftID = UUID()

        try await store.upsert(
            makeWorkflowSnapshot(
                id: draftID,
                workflowState: .submitting,
                vendorName: "Original Vendor",
                updatedAt: Date()
            )
        )

        try await store.upsert(
            makeWorkflowSnapshot(
                id: draftID,
                workflowState: .reviewEdited,
                vendorName: "Regressed Vendor",
                updatedAt: Date().addingTimeInterval(60)
            )
        )

        let loaded = await store.load(id: draftID)
        #expect(loaded?.workflowState == .submitting)
        #expect(loaded?.state.vendorName == "Original Vendor")
    }

    @Test func draftStoreAllowsFailedDraftRecovery() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-draft-store-recovery-\(UUID().uuidString).json")
        let store = ReviewDraftStore(fileURL: fileURL)
        let draftID = UUID()

        try await store.upsert(
            makeWorkflowSnapshot(
                id: draftID,
                workflowState: .failed,
                vendorName: "Needs Attention",
                updatedAt: Date()
            )
        )

        try await store.upsert(
            makeWorkflowSnapshot(
                id: draftID,
                workflowState: .reviewEdited,
                vendorName: "Recovered Draft",
                updatedAt: Date().addingTimeInterval(60)
            )
        )

        let loaded = await store.load(id: draftID)
        #expect(loaded?.workflowState == .reviewEdited)
        #expect(loaded?.state.vendorName == "Recovered Draft")
    }

    @Test func reviewEditedProgressRespondsToReadinessSignals() {
        let now = Date()
        let lowReadinessItem = POItem(
            description: "Unknown line",
            quantity: 1,
            unitCost: 10,
            partNumber: nil,
            confidence: 0.3,
            kind: .unknown,
            kindConfidence: 0.2,
            kindReasons: []
        )
        let highReadinessItem = POItem(
            description: "Brake pad",
            quantity: 1,
            unitCost: 100,
            partNumber: "BP-1",
            confidence: 0.95,
            kind: .part,
            kindConfidence: 0.95,
            kindReasons: []
        )

        let lowReadiness = makeWorkflowSnapshot(
            id: UUID(),
            workflowState: .reviewEdited,
            vendorName: "",
            updatedAt: now,
            orderId: "",
            serviceId: "",
            items: [lowReadinessItem],
            modeUIRawValue: "quickAdd"
        )
        let highReadiness = makeWorkflowSnapshot(
            id: UUID(),
            workflowState: .reviewEdited,
            vendorName: "Advance Auto Parts",
            updatedAt: now,
            selectedVendorId: "vendor-1",
            orderId: "WO-100",
            serviceId: "SVC-100",
            items: [highReadinessItem],
            modeUIRawValue: "quickAdd"
        )

        #expect(highReadiness.workflowProgressEstimate > lowReadiness.workflowProgressEstimate)
        #expect(highReadiness.workflowProgressEstimate >= 0.88)
    }

    @Test func reviewLiveStatusUsesWorkflowDetailSignals() {
        let snapshot = makeWorkflowSnapshot(
            id: UUID(),
            workflowState: .reviewEdited,
            vendorName: "Vendor",
            updatedAt: Date(),
            workflowDetail: "Line items reordered."
        )

        #expect(snapshot.liveActivityPayload?.status == "Line order updated")
    }
}

private func makeWorkflowSnapshot(
    id: UUID,
    workflowState: ReviewDraftSnapshot.WorkflowState,
    vendorName: String,
    updatedAt: Date,
    selectedVendorId: String? = nil,
    orderId: String = "",
    serviceId: String = "",
    items: [POItem] = [],
    modeUIRawValue: String = "quickAdd",
    workflowDetail: String? = nil
) -> ReviewDraftSnapshot {
    let parsedInvoice = ParsedInvoice(
        vendorName: vendorName,
        poNumber: nil,
        invoiceNumber: nil,
        totalCents: nil,
        items: [],
        header: POHeaderFields()
    )

    return ReviewDraftSnapshot(
        id: id,
        createdAt: updatedAt.addingTimeInterval(-120),
        updatedAt: updatedAt,
        state: ReviewDraftSnapshot.State(
            parsedInvoice: ReviewDraftSnapshot.ParsedInvoiceSnapshot(invoice: parsedInvoice),
            vendorName: vendorName,
            vendorPhone: "",
            vendorInvoiceNumber: "",
            poReference: "",
            notes: "",
            selectedVendorId: selectedVendorId,
            orderId: orderId,
            serviceId: serviceId,
            items: items,
            modeUIRawValue: modeUIRawValue,
            ignoreTaxOverride: true,
            selectedPOId: nil,
            selectedTicketId: nil,
            workflowStateRawValue: workflowState.rawValue,
            workflowDetail: workflowDetail ?? workflowState.statusLabel
        )
    )
}
