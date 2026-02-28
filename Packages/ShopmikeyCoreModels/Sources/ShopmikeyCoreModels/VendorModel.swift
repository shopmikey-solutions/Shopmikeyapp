//
//  VendorModel.swift
//  POScannerApp
//

import Foundation

public struct VendorModel: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
