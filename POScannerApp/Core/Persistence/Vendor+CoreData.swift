//
//  Vendor+CoreData.swift
//  POScannerApp
//

import CoreData
import Foundation

@objc(Vendor)
public final class Vendor: NSManagedObject {
    public override func awakeFromInsert() {
        super.awakeFromInsert()

        id = ""
        name = ""
        normalizedName = ""
    }
}

extension Vendor {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Vendor> {
        NSFetchRequest<Vendor>(entityName: "Vendor")
    }

    @NSManaged public var id: String
    @NSManaged public var name: String
    @NSManaged public var normalizedName: String
}

extension Vendor: Identifiable {}

