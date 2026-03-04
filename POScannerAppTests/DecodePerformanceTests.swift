//
//  DecodePerformanceTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreNetworking
import Testing

private final class DecodePerformanceURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
struct DecodePerformanceTests {
    @Test func purchaseOrderPageDecodeStaysWithinBudget() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DecodePerformanceURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let rows = (0..<50).map { index in
            """
            {
              "id": "po_\(index)",
              "vendor_name": "Vendor \(index)",
              "status": "Ordered",
              "parts": [
                { "name": "Part \(index)", "quantity": 1, "cost_cents": 1234, "part_number": "PN-\(index)" }
              ]
            }
            """
        }.joined(separator: ",")

        let responseBody = Data("{\"data\":[\(rows)]}".utf8)
        DecodePerformanceURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (response, responseBody)
        }

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" }
        )
        let api = ShopmonkeyAPI(client: client)

        let start = ContinuousClock.now
        let purchaseOrders = try await api.fetchOpenPurchaseOrders()
        let elapsed = start.duration(to: .now)

        #expect(purchaseOrders.count == 50)
        #expect(elapsed < .seconds(2))
    }
}
