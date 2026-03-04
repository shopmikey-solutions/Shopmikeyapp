import SwiftUI
import ShopmikeyCoreModels
import XCTest
@testable import POScannerApp

@MainActor
final class ReviewModesSnapshotTests: XCTestCase {
    func testAttachLightDefault() {
        SnapshotTestSupport.assertSnapshot(
            name: "Review_Attach__light__L",
            view: makeView(mode: .attach),
            config: .lightDefault
        )
    }

    func testAttachDarkDefault() {
        SnapshotTestSupport.assertSnapshot(
            name: "Review_Attach__dark__L",
            view: makeView(mode: .attach),
            config: .darkDefault
        )
    }

    func testQuickAddLightDefault() {
        SnapshotTestSupport.assertSnapshot(
            name: "Review_QuickAdd__light__L",
            view: makeView(mode: .quickAdd),
            config: .lightDefault
        )
    }

    func testQuickAddDarkDefault() {
        SnapshotTestSupport.assertSnapshot(
            name: "Review_QuickAdd__dark__L",
            view: makeView(mode: .quickAdd),
            config: .darkDefault
        )
    }

    func testRestockLightDefault() {
        SnapshotTestSupport.assertSnapshot(
            name: "Review_Restock__light__L",
            view: makeView(mode: .restock),
            config: .lightDefault
        )
    }

    func testRestockDarkDefault() {
        SnapshotTestSupport.assertSnapshot(
            name: "Review_Restock__dark__L",
            view: makeView(mode: .restock),
            config: .darkDefault
        )
    }

    private func makeView(mode: ReviewViewModel.ModeUI) -> some View {
        let parsedInvoice = sampleParsedInvoice
        let draftSnapshot = makeDraftSnapshot(mode: mode, parsedInvoice: parsedInvoice)
        let environment = sampleEnvironment()

        return NavigationStack {
            ReviewView(
                environment: environment,
                parsedInvoice: parsedInvoice,
                draftSnapshot: draftSnapshot
            )
        }
    }

    private func sampleEnvironment() -> AppEnvironment {
        let draftFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot_review_drafts.json", isDirectory: false)
        try? FileManager.default.removeItem(at: draftFileURL)

        return AppEnvironment.test(
            dataController: DataController(inMemory: true),
            reviewDraftStore: ReviewDraftStore(fileURL: draftFileURL)
        )
    }

    private func makeDraftSnapshot(mode: ReviewViewModel.ModeUI, parsedInvoice: ParsedInvoice) -> ReviewDraftSnapshot {
        ReviewDraftSnapshot(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: ReviewDraftSnapshot.State(
                parsedInvoice: ReviewDraftSnapshot.ParsedInvoiceSnapshot(invoice: parsedInvoice),
                vendorName: "Metro Auto Supply",
                vendorPhone: "555-0100",
                vendorEmail: "parts@metro.example",
                vendorNotes: "Preferred regional supplier",
                vendorInvoiceNumber: "INV-1001",
                poReference: "",
                notes: "Deliver to bay 3.",
                selectedVendorId: "vendor-fixed-001",
                orderId: "WO-2001",
                serviceId: "SVC-77",
                items: samplePOItems,
                modeUIRawValue: mode.rawValue,
                ignoreTaxOverride: false,
                selectedPOId: nil,
                selectedTicketId: nil,
                workflowStateRawValue: ReviewDraftSnapshot.WorkflowState.reviewEdited.rawValue,
                workflowDetail: "Snapshot baseline"
            )
        )
    }

    private var sampleParsedInvoice: ParsedInvoice {
        ParsedInvoice(
            vendorName: nil,
            poNumber: nil,
            invoiceNumber: "INV-1001",
            totalCents: 46147,
            items: [
                ParsedLineItem(
                    name: "Brake Pad Set Ceramic",
                    quantity: 2,
                    costCents: 12999,
                    partNumber: "BRK-100",
                    confidence: 0.98,
                    kind: .part,
                    kindConfidence: 0.98,
                    kindReasons: ["deterministic fixture"]
                ),
                ParsedLineItem(
                    name: "Performance Tire 225/45R17",
                    quantity: 2,
                    costCents: 14999,
                    partNumber: "TIR-22545",
                    confidence: 0.96,
                    kind: .tire,
                    kindConfidence: 0.96,
                    kindReasons: ["deterministic fixture"]
                ),
                ParsedLineItem(
                    name: "Shop Supplies Fee",
                    quantity: 1,
                    costCents: 1599,
                    partNumber: nil,
                    confidence: 0.90,
                    kind: .fee,
                    kindConfidence: 0.90,
                    kindReasons: ["deterministic fixture"]
                )
            ],
            header: POHeaderFields(
                vendorName: "",
                vendorPhone: nil,
                vendorEmail: nil,
                vendorInvoiceNumber: "INV-1001",
                poReference: "",
                workOrderId: "WO-2001",
                serviceId: "SVC-77",
                terms: "Net 30",
                notes: "Snapshot fixture"
            )
        )
    }

    private var samplePOItems: [POItem] {
        [
            POItem(
                id: UUID(uuidString: "AAAA1111-BBBB-2222-CCCC-333333333333")!,
                description: "Brake Pad Set Ceramic",
                sku: "BRK-100",
                quantity: 2,
                unitCost: Decimal(string: "129.99") ?? 0,
                partNumber: "BRK-100",
                confidence: 0.98,
                kind: .part,
                kindConfidence: 0.98,
                kindReasons: ["deterministic fixture"]
            ),
            POItem(
                id: UUID(uuidString: "DDDD4444-EEEE-5555-FFFF-666666666666")!,
                description: "Performance Tire 225/45R17",
                sku: "TIR-22545",
                quantity: 2,
                unitCost: Decimal(string: "149.99") ?? 0,
                partNumber: "TIR-22545",
                confidence: 0.96,
                kind: .tire,
                kindConfidence: 0.96,
                kindReasons: ["deterministic fixture"]
            ),
            POItem(
                id: UUID(uuidString: "77777777-8888-9999-AAAA-BBBBBBBBBBBB")!,
                description: "Shop Supplies Fee",
                sku: "",
                quantity: 1,
                unitCost: Decimal(string: "15.99") ?? 0,
                partNumber: nil,
                confidence: 0.90,
                kind: .fee,
                kindConfidence: 0.90,
                kindReasons: ["deterministic fixture"]
            )
        ]
    }
}
