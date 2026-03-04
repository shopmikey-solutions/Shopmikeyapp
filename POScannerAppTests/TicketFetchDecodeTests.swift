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
            baseURL: ShopmonkeyBaseURL.sandboxV3,
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
            baseURL: ShopmonkeyBaseURL.sandboxV3,
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

    @Test func fetchOpenTicketsPrefersCanonicalIDOverPublicIDWhenBothExist() async throws {
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
                      "public_id": "1697",
                      "id": "order_1697",
                      "ticket_number": "RO-1697",
                      "status": "Open"
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
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" }
        )
        let api = ShopmonkeyAPI(client: client)

        let tickets = try await api.fetchOpenTickets()
        #expect(tickets.count == 1)
        #expect(tickets.first?.id == "order_1697")
    }

    @Test func fetchTicketDecodesLineItemsNestedUnderServices() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TicketURLProtocol.self]
        let session = URLSession(configuration: configuration)

        TicketURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/order/order_nested_service_lines")

            let body = Data(
                #"""
                {
                  "data": {
                    "id": "order_nested_service_lines",
                    "ticket_number": "RO-3101",
                    "status": "Open",
                    "services": [
                      {
                        "id": "svc_1",
                        "name": "Brake Service",
                        "parts": [
                          {
                            "id": "svc_part_1",
                            "description": "Front Brake Pad Set",
                            "part_number": "PAD-101",
                            "quantity": 2,
                            "unit_price": 79.95
                          }
                        ],
                        "labor": [
                          {
                            "id": "svc_labor_1",
                            "description": "Brake Labor",
                            "quantity": 1,
                            "unit_price": 120
                          }
                        ]
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
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" }
        )

        let api = ShopmonkeyAPI(client: client)
        let ticket = try await api.fetchTicket(id: "order_nested_service_lines")

        #expect(ticket.id == "order_nested_service_lines")
        #expect(ticket.lineItems.count == 2)
        #expect(ticket.lineItems.map(\.id).contains("svc_part_1"))
        #expect(ticket.lineItems.map(\.id).contains("svc_labor_1"))
    }

    @Test func fetchTicketHydratesLineItemsFromServiceDetailsWhenOrderPayloadIsSparse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TicketURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var seenPaths: [String] = []
        TicketURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            seenPaths.append(url.path)

            switch url.path {
            case "/v3/order/1697":
                let body: Data
                if seenPaths.filter({ $0 == "/v3/order/1697" }).count == 1 {
                    body = Data(
                        #"""
                        {
                          "data": {
                            "id": "1697",
                            "order_id": "order_1697",
                            "ticket_number": "RO-1697",
                            "status": "Open"
                          }
                        }
                        """#.utf8
                    )
                } else {
                    body = Data(
                        #"""
                        {
                          "data": {
                            "id": "1697",
                            "order_id": "order_1697"
                          }
                        }
                        """#.utf8
                    )
                }

                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/1697/service":
                guard let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, Data("{}".utf8))

            case "/v3/order/order_1697/service":
                let body = Data(#"{"data":[{"id":"svc_1","name":"Brake Service"}]}"#.utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/order_1697/part":
                let body = Data(#"{"data":[]}"#.utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/order_1697/tire":
                let body = Data(#"{"data":[]}"#.utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/order_1697/service/svc_1":
                let body = Data(
                    #"""
                    {
                      "data": {
                        "id": "svc_1",
                        "order_id": "order_1697",
                        "parts": [
                          {
                            "id": "svc_part_1",
                            "description": "Brake Pad",
                            "part_number": "PAD-001",
                            "quantity": 2,
                            "unit_price": 54.5
                          }
                        ],
                        "labors": [
                          {
                            "id": "svc_labor_1",
                            "description": "Install labor",
                            "hours": 1,
                            "rate_cents": 12000
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

            default:
                throw URLError(.unsupportedURL)
            }
        }

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" }
        )
        let api = ShopmonkeyAPI(client: client)

        let ticket = try await api.fetchTicket(id: "1697")
        #expect(ticket.id == "1697")
        #expect(ticket.lineItems.map(\.id).contains("svc_part_1"))
        #expect(ticket.lineItems.map(\.id).contains("svc_labor_1"))
        #expect(
            seenPaths == [
                "/v3/order/1697",
                "/v3/order/1697/service",
                "/v3/order/1697",
                "/v3/order/order_1697/service",
                "/v3/order/order_1697/part",
                "/v3/order/order_1697/tire",
                "/v3/order/order_1697/service/svc_1"
            ]
        )
    }

    @Test func fetchTicketHydratesLineItemsFromOrderPartEndpointWhenServiceEndpointReturnsEmptyList() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TicketURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var seenPaths: [String] = []
        TicketURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            seenPaths.append(url.path)

            switch url.path {
            case "/v3/order/1697":
                let body = Data(
                    #"""
                    {
                      "data": {
                        "id": "1697",
                        "order_id": "order_1697",
                        "ticket_number": "RO-1697",
                        "status": "Open"
                      }
                    }
                    """#.utf8
                )
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/1697/service":
                let body = Data(#"{"data":[]}"#.utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/order_1697/service":
                let body = Data(#"{"data":[]}"#.utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/order_1697/part":
                let body = Data(
                    #"""
                    {
                      "data": [
                        {
                          "id": "part_1",
                          "type": "part",
                          "part_number": "PAD-001",
                          "description": "Front Brake Pads",
                          "quantity": 2,
                          "unit_price": 54.5
                        }
                      ]
                    }
                    """#.utf8
                )
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/order_1697/tire":
                let body = Data(#"{"data":[]}"#.utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            default:
                throw URLError(.unsupportedURL)
            }
        }

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" }
        )
        let api = ShopmonkeyAPI(client: client)

        let ticket = try await api.fetchTicket(id: "1697")
        #expect(ticket.id == "1697")
        #expect(ticket.lineItems.map(\.id) == ["part_1"])
        #expect(ticket.lineItems.first?.kind == "part")
        #expect(
            seenPaths == [
                "/v3/order/1697",
                "/v3/order/1697/service",
                "/v3/order/1697",
                "/v3/order/order_1697/service",
                "/v3/order/order_1697/part",
                "/v3/order/order_1697/tire"
            ]
        )
    }
}
