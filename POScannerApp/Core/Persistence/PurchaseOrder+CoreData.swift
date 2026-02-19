//
//  PurchaseOrder+CoreData.swift
//  POScannerApp
//

import CoreData
import Foundation

enum PurchaseOrderStatusBucket: Equatable {
    case submitted
    case pending
    case failed
    case ignored

    init(rawStatus: String) {
        let normalized = Self.normalized(rawStatus)
        guard !normalized.isEmpty else {
            self = .ignored
            return
        }

        switch normalized {
        case "submitted", "success", "succeeded", "complete", "completed", "closed", "fulfilled", "received":
            self = .submitted
        case "draft", "submitting", "pending", "queued", "queue", "in_progress", "in-progress", "processing", "retrying", "retry", "open", "created", "ordered":
            self = .pending
        case "failed", "error", "errored", "rejected", "cancelled", "canceled":
            self = .failed
        default:
            self = .ignored
        }
    }

    var countsAsTrackedScan: Bool {
        self != .ignored
    }

    var countsAsAttention: Bool {
        self == .pending || self == .failed
    }

    var allowsRetry: Bool {
        self == .failed
    }

    static func normalized(_ rawStatus: String) -> String {
        rawStatus
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

@objc(PurchaseOrder)
public final class PurchaseOrder: NSManagedObject {
    public override func awakeFromInsert() {
        super.awakeFromInsert()

        id = UUID()
        date = Date()
        vendorName = ""
        status = "draft"
        totalAmount = 0
    }
}

extension PurchaseOrder {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<PurchaseOrder> {
        NSFetchRequest<PurchaseOrder>(entityName: "PurchaseOrder")
    }

    @NSManaged public var id: UUID
    @NSManaged public var vendorName: String
    @NSManaged public var poNumber: String?
    @NSManaged public var orderId: String?
    @NSManaged public var serviceId: String?
    @NSManaged public var date: Date
    @NSManaged public var submittedAt: Date?
    @NSManaged public var totalAmount: Double
    @NSManaged public var status: String
    @NSManaged public var lastError: String?
    @NSManaged public var items: Set<Item>?

    public var itemsSorted: [Item] {
        (items ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension PurchaseOrder: Identifiable {}
