//
//  PreviewFixtures.swift
//  POScannerApp
//

import CoreData
import ShopmikeyCoreModels
import SwiftUI

enum PreviewFixtures {
    static func makeEnvironment(seedHistory: Bool = false) -> AppEnvironment {
        let environment = AppEnvironment.preview
        if seedHistory {
            seedHistoryIfNeeded(in: environment.dataController.viewContext)
        }
        return environment
    }

    static var parsedInvoice: ParsedInvoice {
        ParsedInvoice(
            vendorName: "METRO AUTO PARTS SUPPLY",
            poNumber: "PO-99012",
            invoiceNumber: "MAP-45821",
            totalCents: 164_212,
            items: [
                ParsedLineItem(
                    name: "Front Brake Pad Set - Ceramic",
                    quantity: 6,
                    costCents: 6_800,
                    partNumber: "ACD-41-993",
                    confidence: 0.95,
                    kind: .part,
                    kindConfidence: 0.9,
                    kindReasons: ["preview fixture"]
                ),
                ParsedLineItem(
                    name: "225/60/16 Primacy Michelin",
                    quantity: 4,
                    costCents: 18_000,
                    partNumber: "MICH-123",
                    confidence: 0.9,
                    kind: .tire,
                    kindConfidence: 0.82,
                    kindReasons: ["preview fixture"]
                ),
                ParsedLineItem(
                    name: "Shipping",
                    quantity: 1,
                    costCents: 4_500,
                    partNumber: nil,
                    confidence: 0.82,
                    kind: .fee,
                    kindConfidence: 0.76,
                    kindReasons: ["preview fixture"]
                )
            ],
            header: POHeaderFields(
                vendorName: "METRO AUTO PARTS SUPPLY",
                vendorInvoiceNumber: "MAP-45821",
                poReference: "PO-99012",
                workOrderId: "",
                serviceId: "",
                terms: "Net 15",
                notes: "Preview fixture"
            )
        )
    }

    static var lineItem: POItem {
        POItem(
            description: "Front Brake Pad Set - Ceramic",
            sku: "ACD-41-993",
            quantity: 6,
            unitCost: 68,
            isTaxable: true,
            partNumber: "ACD-41-993",
            confidence: 0.92,
            kind: .part,
            kindConfidence: 0.86,
            kindReasons: ["preview fixture"]
        )
    }

    static func firstHistoryOrder(in context: NSManagedObjectContext) -> PurchaseOrder {
        seedHistoryIfNeeded(in: context)

        let request: NSFetchRequest<PurchaseOrder> = PurchaseOrder.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.fetchLimit = 1

        let fetched = (try? context.fetch(request)) ?? []
        if let first = fetched.first {
            return first
        }

        let fallback: PurchaseOrder = (try? context.insertObject(PurchaseOrder.self)) ?? PurchaseOrder(context: context)
        fallback.vendorName = "Preview Vendor"
        fallback.status = "submitted"
        fallback.totalAmount = 0
        try? context.save()
        return fallback
    }

    static var previewShopmonkeyService: any ShopmonkeyServicing {
        PreviewShopmonkeyService()
    }

    private static func seedHistoryIfNeeded(in context: NSManagedObjectContext) {
        context.performAndWait {
            let request: NSFetchRequest<PurchaseOrder> = PurchaseOrder.fetchRequest()
            request.fetchLimit = 1
            let hasRows = ((try? context.count(for: request)) ?? 0) > 0
            if hasRows {
                return
            }

            do {
                let calendar = Calendar.current
                let now = Date()
                let earlier = calendar.date(byAdding: .hour, value: -1, to: now) ?? now
                let oldest = calendar.date(byAdding: .hour, value: -2, to: now) ?? now

                let submitted: PurchaseOrder = try context.insertObject(PurchaseOrder.self)
                submitted.vendorName = "METRO AUTO PARTS SUPPLY"
                submitted.poNumber = "MAP-45821"
                submitted.totalAmount = 3114.12
                submitted.status = "submitted"
                submitted.date = now
                submitted.submittedAt = now

                let failed: PurchaseOrder = try context.insertObject(PurchaseOrder.self)
                failed.vendorName = "METRO AUTO PARTS SUPPLY"
                failed.poNumber = "PO-99012"
                failed.totalAmount = 2192.00
                failed.status = "failed"
                failed.lastError = "Sandbox rejected missing vendor id"
                failed.date = earlier

                let pending: PurchaseOrder = try context.insertObject(PurchaseOrder.self)
                pending.vendorName = "METRO AUTO PARTS SUPPLY"
                pending.poNumber = "PO-99013"
                pending.totalAmount = 2237.00
                pending.status = "submitting"
                pending.date = oldest

                let item: Item = try context.insertObject(Item.self)
                item.name = "Front Brake Pad Set - Ceramic"
                item.quantity = 6
                item.cost = 68
                item.purchaseOrder = submitted

                try context.save()
            } catch {
                assertionFailure("Failed to seed preview history: \(error)")
            }
        }
    }
}

private struct PreviewShopmonkeyService: ShopmonkeyServicing {
    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        CreateVendorResponse(id: "preview-vendor", name: request.name)
    }

    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        CreatePartResponse(id: "preview-part", name: request.name)
    }

    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] {
        []
    }

    func fetchOrders() async throws -> [OrderSummary] {
        [
            OrderSummary(id: "preview-order-1", number: "506", customerName: "Shopmikey Inc."),
            OrderSummary(id: "preview-order-2", number: "507", customerName: "Walk-in")
        ]
    }

    func fetchServices(orderId: String) async throws -> [ServiceSummary] {
        [
            ServiceSummary(id: "preview-service-1", name: "Brake Service"),
            ServiceSummary(id: "preview-service-2", name: "Alignment")
        ]
    }

    func searchVendors(name: String) async throws -> [VendorSummary] {
        [
            VendorSummary(id: "preview-vendor", name: "METRO AUTO PARTS SUPPLY")
        ]
    }

    func testConnection() async throws {}
}
