//
//  TicketModel.swift
//  ShopmikeyCoreModels
//

import Foundation

public struct TicketModel: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var number: String?
    public var displayNumber: String?
    public var status: String?
    public var customerName: String?
    public var vehicleSummary: String?
    public var updatedAt: Date?
    public var lineItems: [TicketLineItem]

    public init(
        id: String,
        number: String? = nil,
        displayNumber: String? = nil,
        status: String? = nil,
        customerName: String? = nil,
        vehicleSummary: String? = nil,
        updatedAt: Date? = nil,
        lineItems: [TicketLineItem] = []
    ) {
        self.id = id
        self.number = number
        self.displayNumber = displayNumber
        self.status = status
        self.customerName = customerName
        self.vehicleSummary = vehicleSummary
        self.updatedAt = updatedAt
        self.lineItems = lineItems
    }
}
