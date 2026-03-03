//
//  ScanHubRoute.swift
//  POScannerApp
//

import Foundation

enum ScanLaunchAction: Equatable, Hashable, Sendable {
    case none
    case openComposer
    case cameraDocument
    case addFromPhoto
    case addFromFiles
    case openReviewFixture
    case resumeDraft(UUID)
}

extension ScanLaunchAction {
    fileprivate var routeToken: String {
        switch self {
        case .none:
            return "none"
        case .openComposer:
            return "open-composer"
        case .cameraDocument:
            return "camera-document"
        case .addFromPhoto:
            return "add-from-photo"
        case .addFromFiles:
            return "add-from-files"
        case .openReviewFixture:
            return "open-review-fixture"
        case .resumeDraft(let draftID):
            return "resume-draft-\(draftID.uuidString)"
        }
    }
}

enum ScanHubRoute: Identifiable, Equatable, Hashable {
    case scanWorkflow(ScanLaunchAction)
    case scanNextStep(scannedCode: String?)
    case inventoryLookup(scannedCode: String?)
    case receivePurchaseOrder(id: String, scannedCode: String?)
    case purchaseOrderDraft
    case inventory
    case tickets
    case purchaseOrders
    case history
    case settings

    var id: String {
        switch self {
        case .scanWorkflow(let action):
            return "scan-workflow-\(action.routeToken)"
        case .scanNextStep(let scannedCode):
            return "scan-next-step-\(scannedCode ?? "none")"
        case .inventoryLookup(let scannedCode):
            return "inventory-lookup-\(scannedCode ?? "none")"
        case .receivePurchaseOrder(let id, let scannedCode):
            return "receive-po-\(id)-\(scannedCode ?? "none")"
        case .purchaseOrderDraft:
            return "purchase-order-draft"
        case .inventory:
            return "inventory"
        case .tickets:
            return "tickets"
        case .purchaseOrders:
            return "purchase-orders"
        case .history:
            return "history"
        case .settings:
            return "settings"
        }
    }
}
