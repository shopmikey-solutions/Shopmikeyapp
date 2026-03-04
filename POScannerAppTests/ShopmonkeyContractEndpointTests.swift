//
//  ShopmonkeyContractEndpointTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreNetworking
import Testing

private final class ShopmonkeyContractURLProtocol: URLProtocol {
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
struct ShopmonkeyContractEndpointTests {
    @Test func createPartUsesServiceScopedOrderEndpoint() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShopmonkeyContractURLProtocol.self]
        let session = URLSession(configuration: configuration)

        ShopmonkeyContractURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            #expect(request.httpMethod == "POST")
            #expect(url.path == "/v3/order/order_123/service/service_456/part")

            let body = Data(#"{"id":"created_part_1","name":"Brake Pad"}"#.utf8)
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

        let response = try await api.createPart(
            orderId: "order_123",
            serviceId: "service_456",
            request: CreatePartRequest(
                name: "Brake Pad",
                quantity: 1,
                partNumber: "BP-100",
                wholesaleCostCents: 1299,
                vendorId: "vendor_1",
                purchaseOrderId: nil
            )
        )

        #expect(response.id == "created_part_1")
    }

    @Test func fetchServicesUsesOrderServiceEndpoint() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShopmonkeyContractURLProtocol.self]
        let session = URLSession(configuration: configuration)

        ShopmonkeyContractURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            #expect(request.httpMethod == "GET")
            #expect(url.path == "/v3/order/order_789/service")

            let body = Data(#"{"data":[{"id":"svc_1","name":"Brakes"}]}"#.utf8)
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

        let services = try await api.fetchServices(orderId: "order_789")
        #expect(services.count == 1)
        #expect(services.first?.id == "svc_1")
    }

    @Test func fetchServicesTreatsNotFoundAsNoServices() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShopmonkeyContractURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var seenPaths: [String] = []
        ShopmonkeyContractURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            #expect(request.httpMethod == "GET")
            seenPaths.append(url.path)

            switch url.path {
            case "/v3/order/order_missing/service", "/v3/order/order_missing":
                let body = Data("{}".utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil) else {
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

        let services = try await api.fetchServices(orderId: "order_missing")
        #expect(services.isEmpty)
        #expect(seenPaths == ["/v3/order/order_missing/service", "/v3/order/order_missing"])
    }

    @Test func fetchServicesFallsBackToOrderDetailServicesWhenServiceRouteIsNotFound() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShopmonkeyContractURLProtocol.self]
        let session = URLSession(configuration: configuration)

        ShopmonkeyContractURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            #expect(request.httpMethod == "GET")

            switch url.path {
            case "/v3/order/order_legacy/service":
                let body = Data("{}".utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/order_legacy":
                let body = Data(
                    #"""
                    {
                      "data": {
                        "id": "order_legacy",
                        "services": [
                          { "service_id": "svc_fallback_1", "name": "Brake Service" }
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

        let services = try await api.fetchServices(orderId: "order_legacy")
        #expect(services.map(\.id) == ["svc_fallback_1"])
        #expect(services.first?.name == "Brake Service")
    }

    @Test func fetchServicesRetriesWithCanonicalOrderIDWhenPublicIDWasUsedInitially() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShopmonkeyContractURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var seenPaths: [String] = []
        ShopmonkeyContractURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            #expect(request.httpMethod == "GET")
            seenPaths.append(url.path)

            switch url.path {
            case "/v3/order/1697/service":
                let body = Data("{}".utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/1697":
                let body = Data(
                    #"""
                    {
                      "data": {
                        "public_id": "1697",
                        "id": "order_1697"
                      }
                    }
                    """#.utf8
                )
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, body)

            case "/v3/order/order_1697/service":
                let body = Data(#"{"data":[{"id":"svc_1697","name":"Brake Service"}]}"#.utf8)
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

        let services = try await api.fetchServices(orderId: "1697")
        #expect(services.map(\.id) == ["svc_1697"])
        #expect(
            seenPaths == [
                "/v3/order/1697/service",
                "/v3/order/1697",
                "/v3/order/order_1697/service"
            ]
        )
    }

    @Test func contractsDocContainsEndpointRegistryEntries() throws {
        let contractPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/integrations/SHOPMONKEY_CONTRACTS.md")
        let markdown = try String(contentsOf: contractPath, encoding: .utf8)

        #expect(markdown.contains("/order/{orderId}/service/{serviceId}/part"))
        #expect(markdown.contains("/order/{orderId}/service"))
        #expect(markdown.contains("/order/{id}"))
        #expect(markdown.contains("/order"))
    }
}
