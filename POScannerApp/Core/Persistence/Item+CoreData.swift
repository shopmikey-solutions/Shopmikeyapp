//
//  Item+CoreData.swift
//  POScannerApp
//

import CoreData
import Foundation

@objc(Item)
public final class Item: NSManagedObject {
    public override func awakeFromInsert() {
        super.awakeFromInsert()

        id = UUID()
        name = ""
        quantity = 1
        cost = 0
    }
}

extension Item {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Item> {
        NSFetchRequest<Item>(entityName: "Item")
    }

    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var quantity: Int16
    @NSManaged public var cost: Double
    @NSManaged public var purchaseOrder: PurchaseOrder?

    public var lineTotal: Double {
        Double(quantity) * cost
    }
}

extension Item: Identifiable {}

