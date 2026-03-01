//
//  PurchaseOrderReceivingDecodeTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import Testing

private final class PurchaseOrderReceivingURLProtocol: URLProtocol {
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
struct PurchaseOrderReceivingDecodeTests {
    @Test func receivePurchaseOrderLineItemDecodesLineLevelResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderReceivingURLProtocol.self]
        let session = URLSession(configuration: configuration)

        PurchaseOrderReceivingURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(request.httpMethod == "POST")
            #expect(url.path == "/v3/purchase_order/po_42/line_item/li_2/receive")

            let bodyString = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(bodyString.contains("\"line_item_id\":\"li_2\""))
            #expect(bodyString.contains("\"quantity_received\":2"))

            let body = Data(
                #"""
                {
                  "data": {
                    "id": "po_42",
                    "vendor_name": "ACME Supply",
                    "status": "ordered",
                    "parts": [
                      {
                        "name": "Rotor",
                        "part_number": "ROT-2",
                        "quantity": 4,
                        "quantity_received": 2,
                        "cost_cents": 3199
                      }
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

        let purchaseOrder = try await api.receivePurchaseOrderLineItem(
            purchaseOrderId: "po_42",
            lineItemId: "li_2",
            quantityReceived: 2
        )

        #expect(purchaseOrder.id == "po_42")
        #expect(purchaseOrder.status == "ordered")
        let lineItem = try #require(purchaseOrder.lineItems.first)
        #expect(lineItem.partNumber == "ROT-2")
        #expect(NSDecimalNumber(decimal: lineItem.quantityOrdered).doubleValue == 4.0)
        #expect(NSDecimalNumber(decimal: lineItem.quantityReceived ?? 0).doubleValue == 2.0)
    }

    @Test func receivePurchaseOrderLineItemFallsBackToPOLevelReceiveRoute() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderReceivingURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let recorder = RequestPathRecorder()
        PurchaseOrderReceivingURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            recorder.append(url.path)

            if url.path == "/v3/purchase_order/po_7/line_item/li_1/receive" ||
                url.path == "/v3/purchase_order/po_7/part/li_1/receive" {
                guard let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, Data("{}".utf8))
            }

            #expect(url.path == "/v3/purchase_order/po_7/receive")
            let bodyString = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(bodyString.contains("\"line_items\""))
            #expect(bodyString.contains("\"line_item_id\":\"li_1\""))

            let body = Data(
                #"""
                {
                  "result": {
                    "id": "po_7",
                    "status": "received",
                    "parts": [
                      {
                        "name": "Oil Filter",
                        "part_number": "OF-1",
                        "quantity": 3,
                        "quantity_received": 3,
                        "cost_cents": 899
                      }
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

        let purchaseOrder = try await api.receivePurchaseOrderLineItem(
            purchaseOrderId: "po_7",
            lineItemId: "li_1",
            quantityReceived: 3
        )

        #expect(recorder.snapshot() == [
            "/v3/purchase_order/po_7/line_item/li_1/receive",
            "/v3/purchase_order/po_7/part/li_1/receive",
            "/v3/purchase_order/po_7/receive"
        ])
        #expect(purchaseOrder.id == "po_7")
        #expect(purchaseOrder.status == "received")
        let lineItem = try #require(purchaseOrder.lineItems.first)
        #expect(NSDecimalNumber(decimal: lineItem.quantityReceived ?? 0).doubleValue == 3.0)
    }
}

private final class RequestPathRecorder: @unchecked Sendable {
    private var paths: [String] = []
    private let lock = NSLock()

    func append(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}
