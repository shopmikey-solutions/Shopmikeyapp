//
//  ShopmonkeyAPISandboxTests.swift
//  POScannerAppTests
//

import Foundation
import ShopmikeyCoreDiagnostics
import ShopmikeyCoreModels
import Testing
import ShopmikeyCoreNetworking
@testable import POScannerApp

private func fallbackBranchCount(_ branch: String) async -> Int {
    let snapshot = await FallbackAnalyticsStore.shared.snapshot()
    return snapshot.branchCounts[branch, default: 0]
}

private func fallbackRecorder() -> any FallbackAnalyticsRecording {
    ClosureFallbackAnalyticsRecorder { branch, context in
        await FallbackAnalyticsStore.shared.record(branch: branch, context: context)
    }
}

private final class MissingTokenURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestCount: Int = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

private final class RetryOnceURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount: Int = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1

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

private final class PurchaseOrderURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount: Int = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
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

private func requestBodyString(_ request: URLRequest) -> String {
    if let body = request.httpBody, !body.isEmpty {
        return String(data: body, encoding: .utf8) ?? ""
    }

    guard let stream = request.httpBodyStream else {
        return ""
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let chunkSize = 1024
    var buffer = [UInt8](repeating: 0, count: chunkSize)

    while stream.hasBytesAvailable {
        let readCount = stream.read(&buffer, maxLength: chunkSize)
        if readCount < 0 { return "" }
        if readCount == 0 { break }
        data.append(buffer, count: readCount)
    }

    return String(data: data, encoding: .utf8) ?? ""
}

private func requestBodyJSONObject(_ request: URLRequest) -> [String: Any]? {
    guard let data = requestBodyString(request).data(using: .utf8), !data.isEmpty else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func fixtureData(named name: String) throws -> Data {
    let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("Shopmonkey", isDirectory: true)
    let fileURL = fixturesDirectory.appendingPathComponent(name, isDirectory: false)
    return try Data(contentsOf: fileURL)
}

@Suite(.serialized)
struct ShopmonkeyAPISandboxTests {
    @Test func missingTokenThrowsMissingToken() async throws {
        MissingTokenURLProtocol.requestCount = 0

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MissingTokenURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { throw APIError.missingToken },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        do {
            _ = try await api.createVendor(.init(name: "ACME", phone: nil))
            #expect(Bool(false))
        } catch let error as APIError {
            if case .missingToken = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false))
            }
        } catch {
            #expect(Bool(false))
        }

        #expect(MissingTokenURLProtocol.requestCount == 0)
    }

    @Test func status429RetriesOnceThenSucceeds() async throws {
        RetryOnceURLProtocol.requestCount = 0

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryOnceURLProtocol.self]
        let session = URLSession(configuration: configuration)

        actor SleepRecorder {
            var sleeps: [TimeInterval] = []
            func record(_ seconds: TimeInterval) {
                sleeps.append(seconds)
            }
        }

        let recorder = SleepRecorder()

        RetryOnceURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            // Validate endpoint path and that Authorization is present (never logged).
            #expect(url.host == "sandbox-api.shopmonkey.cloud")
            #expect(url.path == "/v3/vendor")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")

            if RetryOnceURLProtocol.requestCount == 1 {
                guard let response = HTTPURLResponse(
                    url: url,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "0"]
                ) else {
                    throw URLError(.badServerResponse)
                }
                return (response, Data())
            }

            let body = Data(#"{"id":"v_1","name":"ACME"}"#.utf8)
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (response, body)
        }

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" },
            sleeper: { seconds in await recorder.record(seconds) },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        let response = try await api.createVendor(.init(name: "ACME", phone: nil))
        #expect(response.id == "v_1")
        #expect(response.name == "ACME")

        let sleeps = await recorder.sleeps
        #expect(RetryOnceURLProtocol.requestCount == 2)
        #expect(sleeps.count == 1)
    }

    @Test func createVendorDecodesWrappedSuccessData() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)

        PurchaseOrderURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/vendor")
            #expect(request.httpMethod == "POST")

            let body = Data(#"{"success":true,"data":{"id":"v_1","name":"Mikey Test"}}"#.utf8)
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (response, body)
        }

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        let created = try await api.createVendor(.init(name: "Mikey Test", phone: nil))
        #expect(created.id == "v_1")
        #expect(created.name == "Mikey Test")
    }

    @Test func searchVendorsDecodesContactDetailsWhenAvailable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)

        PurchaseOrderURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/vendor")
            #expect(url.query?.contains("search=acme") == true)

            let body = Data(
                #"""
                {"data":[{"id":"v_1","name":"ACME Parts","phone_number":"555-1212","email":"parts@acme.example","notes":"Preferred vendor"}]}
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
            tokenProvider: { "token" },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        let vendors = try await api.searchVendors(name: "acme")
        #expect(vendors.count == 1)
        #expect(vendors.first?.id == "v_1")
        #expect(vendors.first?.name == "ACME Parts")
        #expect(vendors.first?.phone == "555-1212")
        #expect(vendors.first?.email == "parts@acme.example")
        #expect(vendors.first?.notes == "Preferred vendor")
    }

    @Test func fetchInventoryDecodesWrappedInventoryList() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let fixture = try fixtureData(named: "inventory_part_search_response.json")

        PurchaseOrderURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.host == "sandbox-api.shopmonkey.cloud")
            #expect(url.path == "/v3/inventory_part/search")
            #expect(url.absoluteString.contains("/v3/v3/") == false)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true)

            let requestJSON = requestBodyJSONObject(request)
            #expect(requestJSON?["limit"] as? String == nil)
            #expect(requestJSON?["skip"] as? String == nil)
            #expect((requestJSON?["limit"] as? NSNumber)?.intValue == 50)
            #expect((requestJSON?["skip"] as? NSNumber)?.intValue == 0)

            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (response, fixture)
        }

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        let items = try await api.fetchInventory()
        #expect(items.count == 2)
        #expect(items.first?.id == "inv_part_1")
        #expect(items.first?.partNumber == "PAD-001")
        #expect(items.first?.description == "Front Brake Pad Set")
        #expect(items.first?.quantityOnHand == 12)
    }

    @Test func fetchInventoryMapsAuthAndTransientErrorsToDiagnostics() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        let cases: [(status: Int, expected: DiagnosticCode)] = [
            (401, .authUnauthorized401),
            (403, .authForbidden403),
            (429, .netRate429),
            (503, .apiServer5xx)
        ]

        for testCase in cases {
            PurchaseOrderURLProtocol.requestHandler = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                #expect(url.path == "/v3/inventory_part/search")
                guard let response = HTTPURLResponse(
                    url: url,
                    statusCode: testCase.status,
                    httpVersion: nil,
                    headerFields: nil
                ) else {
                    throw URLError(.badServerResponse)
                }
                return (response, Data())
            }

            do {
                _ = try await api.fetchInventory()
                #expect(Bool(false))
            } catch let error as APIError {
                #expect(error.diagnosticCode == testCase.expected)
            } catch {
                #expect(Bool(false))
            }
        }
    }

    @Test func addPartLineItemDecodesWrappedCreatedLineItem() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)

        PurchaseOrderURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/order/order_1/part")
            #expect(request.httpMethod == "POST")

            let body = Data(
                #"""
                {
                  "data": {
                    "id": "line_1",
                    "type": "part",
                    "sku": "PAD-001",
                    "part_number": "PAD-001",
                    "description": "Front Brake Pad Set",
                    "quantity": 1,
                    "unit_price": 99.95,
                    "extended_price": 99.95,
                    "vendor_id": "vendor_1"
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
            tokenProvider: { "token" },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        let lineItem = try await api.addPartLineItem(
            toTicketId: "order_1",
            sku: "PAD-001",
            partNumber: "PAD-001",
            description: "Front Brake Pad Set",
            quantity: 1,
            unitPrice: 99.95
        )

        #expect(lineItem.id == "line_1")
        #expect(lineItem.kind == "part")
        #expect(lineItem.sku == "PAD-001")
        #expect(lineItem.partNumber == "PAD-001")
        #expect(lineItem.description == "Front Brake Pad Set")
    }

    @Test func getPurchaseOrdersDecodesWrappedListWithNullableVendorId() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)

        PurchaseOrderURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/purchase_order")

            let body = Data(#"{"data":[{"id":"po_1","vendorId":null,"status":"Draft"}]}"#.utf8)
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (response, body)
        }

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        let purchaseOrders = try await api.getPurchaseOrders()
        #expect(purchaseOrders.count == 1)
        #expect(purchaseOrders.first?.id == "po_1")
        #expect(purchaseOrders.first?.status == "Draft")
        #expect(purchaseOrders.first?.vendorId == nil)
    }

    @Test func getPurchaseOrdersDecodesWhenStatusIsMissing() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)

        PurchaseOrderURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/purchase_order")

            let body = Data(#"{"data":[{"id":"po_2","vendor_id":"v_2","status":null}]}"#.utf8)
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (response, body)
        }

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        let purchaseOrders = try await api.getPurchaseOrders()
        #expect(purchaseOrders.count == 1)
        #expect(purchaseOrders.first?.id == "po_2")
        #expect(purchaseOrders.first?.vendorId == "v_2")
        #expect(purchaseOrders.first?.status == "unknown")
    }

    @Test func createPurchaseOrderSendsCompatibilityKeyVariants() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        PurchaseOrderURLProtocol.requestCount = 0

        PurchaseOrderURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/purchase_order")
            switch request.httpMethod {
            case "GET":
                // Create flow probes statuses from existing purchase orders first.
                let listBody = Data(#"{"data":[{"id":"existing_po","vendorId":"v_existing","status":"Draft"}]}"#.utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, listBody)

            case "POST":
                let bodyString = requestBodyString(request)
                #expect(bodyString.contains(#""vendor_id":"v_1""#))
                #expect(bodyString.contains(#""vendorId":"v_1""#))
                #expect(bodyString.contains(#""parts":["#))
                #expect(bodyString.contains(#""fees":["#))
                #expect(!bodyString.contains(#""line_items":["#))
                #expect(bodyString.contains(#""amount_cents":4500"#))
                #expect(bodyString.contains(#""amountCents":4500"#))
                #expect(bodyString.contains(#""cost_cents":1200"#))
                #expect(bodyString.contains(#""costCents":1200"#))

                let responseBody = Data(#"{"success":true,"data":{"id":"po_1","status":"Draft","calculatedItemsCount":0}}"#.utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, responseBody)

            default:
                throw URLError(.unsupportedURL)
            }
        }

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        let request = CreatePurchaseOrderRequest(
            vendorId: "v_1",
            invoiceNumber: "INV-1",
            status: nil,
            lineItems: [
                CreatePurchaseOrderLineItemRequest(
                    description: "Brake Pads",
                    quantity: 1,
                    unitCostCents: 1200,
                    name: "Brake Pads",
                    partNumber: "BP-1",
                    costCents: 1200,
                    unitCost: 12
                )
            ],
            parts: [
                CreatePurchaseOrderPartRequest(
                    name: "Brake Pads",
                    quantity: 1,
                    costCents: 1200,
                    number: "BP-1",
                    description: "Brake Pads",
                    partNumber: "BP-1"
                )
            ],
            fees: [
                CreatePurchaseOrderFeeRequest(
                    name: "Shipping",
                    amountCents: 4500,
                    description: "Shipping"
                )
            ],
            tires: []
        )

        let response = try await api.createPurchaseOrder(request)
        #expect(response.id == "po_1")
    }

    @Test func createPurchaseOrderSkipsBodyAndCostFallbackWhenStatusIsInvalid() async throws {
        await FallbackAnalyticsStore.shared.clear()
        let initialStatusFallbackCount = await fallbackBranchCount(FallbackBranch.submitStatusFallback)
        UserDefaults.standard.removeObject(forKey: "shopmonkey.preferred_po_status")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PurchaseOrderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        PurchaseOrderURLProtocol.requestCount = 0

        var postBodies: [String] = []
        PurchaseOrderURLProtocol.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v3/purchase_order")

            switch request.httpMethod {
            case "GET":
                let listBody = Data(#"{"data":[]}"#.utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, listBody)

            case "POST":
                let bodyString = requestBodyString(request)
                postBodies.append(bodyString)

                if bodyString.contains(#""status":"draft""#) {
                    let errorBody = Data(#"{"success":false,"message":"body/status must be equal to one of the allowed values"}"#.utf8)
                    guard let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil) else {
                        throw URLError(.badServerResponse)
                    }
                    return (response, errorBody)
                }

                let responseBody = Data(#"{"success":true,"data":{"id":"po_fast","status":"open","calculatedItemsCount":0}}"#.utf8)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                    throw URLError(.badServerResponse)
                }
                return (response, responseBody)

            default:
                throw URLError(.unsupportedURL)
            }
        }

        let client = APIClient(
            baseURL: ShopmonkeyBaseURL.sandboxV3,
            urlSession: session,
            tokenProvider: { "token" },
            fallbackRecorder: fallbackRecorder()
        )
        let api = ShopmonkeyAPI(client: client, fallbackRecorder: fallbackRecorder())

        let request = CreatePurchaseOrderRequest(
            vendorId: "v_1",
            invoiceNumber: "INV-FAST",
            status: "draft",
            lineItems: [
                CreatePurchaseOrderLineItemRequest(
                    description: "Brake Pads",
                    quantity: 1,
                    unitCostCents: 1200,
                    name: "Brake Pads",
                    partNumber: "BP-1",
                    costCents: 1200,
                    unitCost: 12
                )
            ],
            parts: [
                CreatePurchaseOrderPartRequest(
                    name: "Brake Pads",
                    quantity: 1,
                    costCents: 1200,
                    number: "BP-1",
                    description: "Brake Pads",
                    partNumber: "BP-1"
                )
            ],
            fees: [],
            tires: []
        )

        let response = try await api.createPurchaseOrder(request)
        #expect(response.id == "po_fast")
        #expect(postBodies.count == 2)
        #expect(postBodies.first?.contains(#""status":"draft""#) == true)
        #expect(postBodies.last?.contains(#""status":"draft""#) == false)
        #expect(await fallbackBranchCount(FallbackBranch.submitStatusFallback) == initialStatusFallbackCount + 1)
        await FallbackAnalyticsStore.shared.clear()
    }
}
