//
//  POBuilderViewModel.swift
//  POScannerApp
//

import CoreData
import Combine
import Foundation
import ShopmikeyCoreModels

@MainActor
protocol PODraftSubmitting {
    func submitNew(
        payload: POSubmissionPayload,
        mode: SubmissionMode?,
        shouldPersist: Bool,
        context: NSManagedObjectContext,
        ignoreTaxAndTotals: Bool
    ) async -> POSubmissionService.Result
}

extension POSubmissionService: PODraftSubmitting {}

@MainActor
final class POBuilderViewModel: ObservableObject {
    @Published private(set) var draft: PurchaseOrderDraft?
    @Published private(set) var isSubmitting = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastDiagnosticCode: String?

    private let environment: AppEnvironment
    private let draftStore: any PurchaseOrderDraftStoring
    private let submitterFactory: @MainActor () -> any PODraftSubmitting

    init(
        environment: AppEnvironment,
        draftStore: any PurchaseOrderDraftStoring,
        submitterFactory: (@MainActor () -> any PODraftSubmitting)? = nil
    ) {
        self.environment = environment
        self.draftStore = draftStore
        if let submitterFactory {
            self.submitterFactory = submitterFactory
        } else {
            self.submitterFactory = {
                POSubmissionService(
                    shopmonkey: environment.shopmonkeyAPI,
                    authorizeSubmission: { [environment] in
                        try await environment.authenticateForSubmissionIfNeeded(forcePrompt: true)
                    }
                )
            }
        }
    }

    var lines: [PurchaseOrderDraftLine] {
        draft?.lines ?? []
    }

    var vendorNameHint: String {
        draft?.vendorNameHint ?? ""
    }

    var totalAmount: Decimal {
        lines.reduce(.zero) { partial, line in
            guard let unitCost = line.unitCost else { return partial }
            return partial + (max(1, line.quantity) * unitCost)
        }
    }

    var totalAmountFormatted: String {
        Self.currencyFormatter.string(from: NSDecimalNumber(decimal: totalAmount)) ?? "$0.00"
    }

    var hasDraftLines: Bool {
        !lines.isEmpty
    }

    func loadDraft() async {
        draft = await draftStore.loadActiveDraft()
    }

    func addLine(_ line: PurchaseOrderDraftLine) async {
        draft = await draftStore.addLine(line)
        statusMessage = "Added to PO Draft."
        errorMessage = nil
        lastDiagnosticCode = nil
    }

    func addMatchedInventoryItem(_ item: InventoryItem, sourceBarcode: String?) async {
        let line = PurchaseOrderDraftLine(
            sku: normalizedOptionalString(item.sku),
            partNumber: normalizedOptionalString(item.partNumber),
            description: item.description,
            quantity: 1,
            unitCost: item.price > .zero ? item.price : nil,
            sourceBarcode: normalizedOptionalString(sourceBarcode)
        )
        await addLine(line)
    }

    func addManualItem(
        description: String,
        quantity: Decimal,
        unitCost: Decimal?,
        sourceBarcode: String?
    ) async {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            errorMessage = "Description is required."
            statusMessage = nil
            return
        }

        let line = PurchaseOrderDraftLine(
            description: trimmedDescription,
            quantity: max(1, quantity),
            unitCost: unitCost.map { max(0, $0) },
            sourceBarcode: normalizedOptionalString(sourceBarcode)
        )
        await addLine(line)
    }

    func updateVendorNameHint(_ value: String) async {
        draft = await draftStore.setVendorNameHint(value)
    }

    func updateLine(id: UUID, quantity: Decimal, unitCost: Decimal?) async {
        draft = await draftStore.updateLine(id: id, quantity: quantity, unitCost: unitCost)
    }

    func removeLine(id: UUID) async {
        draft = await draftStore.removeLine(id: id)
    }

    func clearDraft() async {
        await draftStore.clearActiveDraft()
        draft = nil
        statusMessage = "Draft cleared."
        errorMessage = nil
        lastDiagnosticCode = nil
    }

    func submitDraft() async {
        guard !isSubmitting else { return }
        guard let draft else {
            errorMessage = "No active draft to submit."
            statusMessage = nil
            return
        }
        guard !draft.lines.isEmpty else {
            errorMessage = "Add at least one line item before submitting."
            statusMessage = nil
            return
        }

        let vendorName = vendorNameHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vendorName.isEmpty else {
            errorMessage = "Vendor name is required."
            statusMessage = nil
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        let payload = POSubmissionPayload(
            vendorName: vendorName,
            notes: "Inventory restock draft",
            items: draft.lines.map(Self.payloadItem(from:))
        )

        let submitter = submitterFactory()
        let result = await submitter.submitNew(
            payload: payload,
            mode: .inventoryRestock,
            shouldPersist: true,
            context: environment.dataController.viewContext,
            ignoreTaxAndTotals: false
        )

        if result.succeeded {
            await draftStore.clearActiveDraft()
            self.draft = nil
            statusMessage = "PO Draft submitted."
            errorMessage = nil
            lastDiagnosticCode = nil
            return
        }

        let message = result.message ?? "Submission failed."
        errorMessage = message
        statusMessage = nil
        lastDiagnosticCode = Self.extractDiagnosticCode(from: message)
    }

    private static func payloadItem(from line: PurchaseOrderDraftLine) -> POItem {
        POItem(
            description: line.description,
            sku: line.sku ?? "",
            quantity: NSDecimalNumber(decimal: max(1, line.quantity)).doubleValue,
            unitCost: max(0, line.unitCost ?? .zero),
            partNumber: line.partNumber,
            confidence: 1,
            kind: .part,
            kindConfidence: 1,
            kindReasons: ["PO draft restock line"]
        )
    }

    private static func extractDiagnosticCode(from message: String) -> String? {
        let pattern = #"ID:\s*([A-Z0-9\-\_]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, options: [], range: range),
              let captureRange = Range(match.range(at: 1), in: message) else {
            return nil
        }
        return String(message[captureRange])
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .current
        return formatter
    }()
}
