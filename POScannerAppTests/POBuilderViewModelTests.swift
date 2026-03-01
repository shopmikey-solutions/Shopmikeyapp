//
//  POBuilderViewModelTests.swift
//  POScannerAppTests
//

import Foundation
import CoreData
import ShopmikeyCoreModels
import Testing
@testable import POScannerApp

@MainActor
@Suite(.serialized)
struct POBuilderViewModelTests {
    private final class SubmissionServiceStub: PODraftSubmitting {
        var capturedPayloads: [POSubmissionPayload] = []
        var capturedModes: [SubmissionMode?] = []
        var result: POSubmissionService.Result

        init(result: POSubmissionService.Result) {
            self.result = result
        }

        func submitNew(
            payload: POSubmissionPayload,
            mode: SubmissionMode?,
            shouldPersist: Bool,
            context: NSManagedObjectContext,
            ignoreTaxAndTotals: Bool
        ) async -> POSubmissionService.Result {
            _ = shouldPersist
            _ = context
            _ = ignoreTaxAndTotals
            capturedPayloads.append(payload)
            capturedModes.append(mode)
            return result
        }
    }

    private struct Harness {
        let fileURL: URL
        let draftStore: PurchaseOrderDraftStore
        let environment: AppEnvironment

        init() {
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("po_builder_vm_tests")
                .appendingPathComponent("\(UUID().uuidString).json")
            try? FileManager.default.removeItem(at: fileURL)
            draftStore = PurchaseOrderDraftStore(fileURL: fileURL)
            environment = .test()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
    }

    @Test func addKnownInventoryLineStoresExpectedFields() async {
        let harness = Harness()
        defer { harness.cleanup() }

        let submitter = SubmissionServiceStub(result: .init(succeeded: true, message: nil, purchaseOrderObjectID: nil))
        let viewModel = POBuilderViewModel(
            environment: harness.environment,
            draftStore: harness.draftStore,
            submitterFactory: { submitter }
        )

        await viewModel.addMatchedInventoryItem(
            InventoryItem(
                id: "inv-1",
                sku: "PAD-001",
                partNumber: "PAD-001",
                description: "Front Brake Pad Set",
                price: 89.50,
                quantityOnHand: 5,
                vendorId: "vendor-1"
            ),
            sourceBarcode: "0123456789"
        )

        #expect(viewModel.lines.count == 1)
        #expect(viewModel.lines.first?.sku == "PAD-001")
        #expect(viewModel.lines.first?.partNumber == "PAD-001")
        #expect(viewModel.lines.first?.unitCost == 89.50)
    }

    @Test func addUnknownManualLineCreatesDraftLine() async {
        let harness = Harness()
        defer { harness.cleanup() }

        let submitter = SubmissionServiceStub(result: .init(succeeded: true, message: nil, purchaseOrderObjectID: nil))
        let viewModel = POBuilderViewModel(
            environment: harness.environment,
            draftStore: harness.draftStore,
            submitterFactory: { submitter }
        )

        await viewModel.addManualItem(
            description: "Mystery Part",
            quantity: 2,
            unitCost: 14.75,
            sourceBarcode: "00001111"
        )

        #expect(viewModel.lines.count == 1)
        #expect(viewModel.lines.first?.description == "Mystery Part")
        #expect(viewModel.lines.first?.quantity == 2)
        #expect(viewModel.lines.first?.unitCost == 14.75)
    }

    @Test func submitSuccessConvertsPayloadAndClearsDraft() async {
        let harness = Harness()
        defer { harness.cleanup() }

        let submitter = SubmissionServiceStub(result: .init(succeeded: true, message: nil, purchaseOrderObjectID: nil))
        let viewModel = POBuilderViewModel(
            environment: harness.environment,
            draftStore: harness.draftStore,
            submitterFactory: { submitter }
        )

        await viewModel.addMatchedInventoryItem(
            InventoryItem(
                id: "inv-2",
                sku: "FLT-100",
                partNumber: "FLT-100",
                description: "Oil Filter",
                price: 12.99,
                quantityOnHand: 10
            ),
            sourceBarcode: "9999"
        )
        await viewModel.updateVendorNameHint("ACME Parts")
        await viewModel.submitDraft()

        #expect(submitter.capturedPayloads.count == 1)
        #expect(submitter.capturedPayloads.first?.vendorName == "ACME Parts")
        #expect(submitter.capturedPayloads.first?.items.count == 1)
        #expect(submitter.capturedModes.first == .inventoryRestock)
        #expect(viewModel.lines.isEmpty)
        #expect(viewModel.statusMessage == "PO Draft submitted.")
        #expect(await harness.draftStore.loadActiveDraft() == nil)
    }

    @Test func submitFailureKeepsDraftAndSurfacesDiagnosticCode() async {
        let harness = Harness()
        defer { harness.cleanup() }

        let submitter = SubmissionServiceStub(
            result: .init(
                succeeded: false,
                message: "Submission failed. (ID: SMK-NET-429-RETRY)",
                purchaseOrderObjectID: nil
            )
        )
        let viewModel = POBuilderViewModel(
            environment: harness.environment,
            draftStore: harness.draftStore,
            submitterFactory: { submitter }
        )

        await viewModel.addManualItem(
            description: "Unknown Seal",
            quantity: 1,
            unitCost: 4.5,
            sourceBarcode: nil
        )
        await viewModel.updateVendorNameHint("Vendor X")
        await viewModel.submitDraft()

        #expect(viewModel.lines.count == 1)
        #expect(viewModel.errorMessage == "Submission failed. (ID: SMK-NET-429-RETRY)")
        #expect(viewModel.lastDiagnosticCode == "SMK-NET-429-RETRY")
        #expect(await harness.draftStore.loadActiveDraft()?.lines.count == 1)
    }
}
