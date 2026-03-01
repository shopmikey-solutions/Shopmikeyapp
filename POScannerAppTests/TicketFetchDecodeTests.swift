//
//  TicketFetchDecodeTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreModels
import ShopmikeyCoreNetworking
import Testing

private final class TicketURLProtocol: URLProtocol {
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
struct TicketFetchDecodeTests {
    @Test func fetchOpenTicketsDecodesAndFiltersClosedStatuses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TicketURLProtocol.self]
        let session = URLSession(configuration: configuration)

        TicketURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/order")

            let body = Data(
                #"""
                {
                  "data": [
                    {
                      "id": "order_open_1",
                      "ticket_number": "RO-1001",
                      "status": "Open",
                      "customer_name": "Alex Driver"
                    },
                    {
                      "id": "order_closed_1",
                      "ticket_number": "RO-1002",
                      "status": "Closed",
                      "customer_name": "Pat Customer"
                    },
                    {
                      "id": "order_open_2",
                      "ticket_number": "RO-1003",
                      "status": "In Progress",
                      "customer_name": "Taylor Buyer"
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
        let tickets = try await api.fetchOpenTickets()

        #expect(tickets.count == 2)
        #expect(tickets.map(\.id).contains("order_open_1"))
        #expect(tickets.map(\.id).contains("order_open_2"))
        #expect(!tickets.map(\.id).contains("order_closed_1"))
        #expect(tickets.allSatisfy { $0.lineItems.isEmpty })
    }

    @Test func fetchTicketDecodesDetailLineItemsFromWrappedResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TicketURLProtocol.self]
        let session = URLSession(configuration: configuration)

        TicketURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/order/order_open_1")

            let body = Data(
                #"""
                {
                  "data": {
                    "id": "order_open_1",
                    "ticket_number": "RO-2001",
                    "display_number": "Ticket 2001",
                    "status": "Open",
                    "customer": {
                      "name": "Jordan Driver"
                    },
                    "vehicle": {
                      "display_name": "2019 Honda Civic"
                    },
                    "updated_at": "2026-03-01T01:02:03Z",
                    "line_items": [
                      {
                        "id": "line_1",
                        "type": "part",
                        "sku": "SKU-100",
                        "part_number": "PN-100",
                        "description": "Front Brake Pad Set",
                        "quantity": 2,
                        "unit_price": 59.95,
                        "extended_price": 119.90,
                        "vendor_id": "vendor_1"
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
        let ticket = try await api.fetchTicket(id: "order_open_1")

        #expect(ticket.id == "order_open_1")
        #expect(ticket.number == "RO-2001")
        #expect(ticket.displayNumber == "Ticket 2001")
        #expect(ticket.status == "Open")
        #expect(ticket.customerName == "Jordan Driver")
        #expect(ticket.vehicleSummary == "2019 Honda Civic")
        #expect(ticket.lineItems.count == 1)

        let line = try #require(ticket.lineItems.first)
        #expect(line.id == "line_1")
        #expect(line.kind == "part")
        #expect(line.sku == "SKU-100")
        #expect(line.partNumber == "PN-100")
        #expect(line.description == "Front Brake Pad Set")
        #expect(line.vendorId == "vendor_1")
        #expect(NSDecimalNumber(decimal: line.quantity).doubleValue == 2.0)
        #expect(NSDecimalNumber(decimal: line.unitPrice ?? 0).doubleValue == 59.95)
        #expect(NSDecimalNumber(decimal: line.extendedPrice ?? 0).doubleValue == 119.9)
    }
}
