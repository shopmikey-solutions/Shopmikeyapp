//
//  PurchaseOrderFetchDecodeTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import Testing

private final class PurchaseOrderURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct PurchaseOrderFetchDecodeTests {
    @Test func fetchOpenPurchaseOrdersDecodesAndFiltersClosedStatuses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)

        PurchaseOrderURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/purchase_order")

            let body = Data(
                #"""
                {
                  "data": [
                    {
                      "id": "po_open_1",
                      "vendor_name": "Alpha Supply",
                      "status": "Draft",
                      "parts": [
                        { "name": "Part A", "quantity": 2, "cost_cents": 1200, "part_number": "PA-1" }
                      ]
                    },
                    {
                      "id": "po_closed_1",
                      "vendor_name": "Closed Vendor",
                      "status": "Closed",
                      "parts": [
                        { "name": "Part B", "quantity": 1, "cost_cents": 500, "part_number": "PB-1" }
                      ]
                    },
                    {
                      "id": "po_open_2",
                      "vendor_name": "Bravo Supply",
                      "status": "Ordered",
                      "fees": [
                        { "name": "Shop Fee", "quantity": 1, "cost_cents": 250 }
                      ]
                    }
                  ]
                }
                """#.utf8
            )

            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }

            return (response, body)
        }

        let client = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            urlSession: session,
            tokenProvider: { "token" }
        )

        let api = ShopmonkeyAPI(client: client)
        let purchaseOrders = try await api.fetchOpenPurchaseOrders()

        #expect(purchaseOrders.count == 2)
        #expect(purchaseOrders.map(\.id).contains("po_open_1"))
        #expect(purchaseOrders.map(\.id).contains("po_open_2"))
        #expect(!purchaseOrders.map(\.id).contains("po_closed_1"))
        #expect(purchaseOrders.first(where: { $0.id == "po_open_1" })?.totalLineCount == 1)
        #expect(purchaseOrders.first(where: { $0.id == "po_open_2" })?.totalLineCount == 1)
    }

    @Test func fetchPurchaseOrderDecodesDetailLineItems() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)

        PurchaseOrderURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/purchase_order/po_1")

            let body = Data(
                #"""
                {
                  "data": {
                    "id": "po_1",
                    "vendor_name": "Alpha Supply",
                    "status": "Draft",
                    "parts": [
                      { "name": "Brake Pad", "quantity": 2, "cost_cents": 1299, "part_number": "BP-100" }
                    ],
                    "fees": [
                      { "name": "Shop Supplies", "quantity": 1, "cost_cents": 250 }
                    ]
                  }
                }
                """#.utf8
            )

            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }

            return (response, body)
        }

        let client = APIClient(
            baseURL: ShopmonkeyAPI.baseURL,
            urlSession: session,
            tokenProvider: { "token" }
        )

        let api = ShopmonkeyAPI(client: client)
        let purchaseOrder = try await api.fetchPurchaseOrder(id: "po_1")

        #expect(purchaseOrder.id == "po_1")
        #expect(purchaseOrder.vendorName == "Alpha Supply")
        #expect(purchaseOrder.status == "Draft")
        #expect(purchaseOrder.lineItems.count == 2)

        let partLine = try #require(purchaseOrder.lineItems.first(where: { $0.kind == "part" }))
        #expect(partLine.partNumber == "BP-100")
        #expect(NSDecimalNumber(decimal: partLine.quantityOrdered).doubleValue == 2.0)
        #expect(NSDecimalNumber(decimal: partLine.unitCost ?? 0).doubleValue == 12.99)
        #expect(NSDecimalNumber(decimal: partLine.extendedCost ?? 0).doubleValue == 25.98)

        let feeLine = try #require(purchaseOrder.lineItems.first(where: { $0.kind == "fee" }))
        #expect(feeLine.description == "Shop Supplies")
        #expect(NSDecimalNumber(decimal: feeLine.quantityOrdered).doubleValue == 1.0)
        #expect(NSDecimalNumber(decimal: feeLine.unitCost ?? 0).doubleValue == 2.5)
    }
}
