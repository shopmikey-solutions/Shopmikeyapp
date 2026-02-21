//
//  ReviewDraftWorkflowTests.swift
//  POScannerAppTests
//

import Foundation
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
            makeSnapshot(
                id: draftID,
                workflowState: .submitting,
                vendorName: "Original Vendor",
                updatedAt: Date()
            )
        )

        try await store.upsert(
            makeSnapshot(
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
            makeSnapshot(
                id: draftID,
                workflowState: .failed,
                vendorName: "Needs Attention",
                updatedAt: Date()
            )
        )

        try await store.upsert(
            makeSnapshot(
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
}

private func makeSnapshot(
    id: UUID,
    workflowState: ReviewDraftSnapshot.WorkflowState,
    vendorName: String,
    updatedAt: Date
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
            selectedVendorId: nil,
            orderId: "",
            serviceId: "",
            items: [],
            modeUIRawValue: "quickAdd",
            ignoreTaxOverride: true,
            selectedPOId: nil,
            selectedTicketId: nil,
            workflowStateRawValue: workflowState.rawValue,
            workflowDetail: workflowState.statusLabel
        )
    )
}
