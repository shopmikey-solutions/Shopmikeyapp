//
//  ShopmonkeyAPI.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreDiagnostics
import ShopmikeyCoreModels

public protocol ShopmonkeyServicing: Sendable {
    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse
    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse
    func createFee(orderId: String, serviceId: String, request: CreateFeeRequest) async throws -> CreatedResourceResponse
    func createTire(orderId: String, serviceId: String, request: CreateTireRequest) async throws -> CreatedResourceResponse
    func createPurchaseOrder(_ request: CreatePurchaseOrderRequest) async throws -> CreatePurchaseOrderResponse
    func getPurchaseOrders() async throws -> [PurchaseOrderResponse]
    func fetchOpenPurchaseOrders() async throws -> [PurchaseOrderSummary]
    func fetchPurchaseOrder(id: String) async throws -> PurchaseOrderDetail
    func receivePurchaseOrderLineItem(
        purchaseOrderId: String,
        lineItemId: String,
        quantityReceived: Decimal?
    ) async throws -> PurchaseOrderDetail
    func fetchOrders() async throws -> [OrderSummary]
    func fetchServices(orderId: String) async throws -> [ServiceSummary]
    func fetchOpenTickets() async throws -> [TicketModel]
    func fetchTicket(id: String) async throws -> TicketModel
    func addPartLineItem(
        toTicketId ticketId: String,
        sku: String?,
        partNumber: String?,
        description: String,
        quantity: Decimal,
        unitPrice: Decimal?
    ) async throws -> TicketLineItem
    func fetchInventory() async throws -> [InventoryItem]
    func searchVendors(name: String) async throws -> [VendorSummary]
    func testConnection() async throws
    func runEndpointProbe() async throws -> ShopmonkeyEndpointProbeReport
}

public extension ShopmonkeyServicing {
    func createFee(orderId: String, serviceId: String, request: CreateFeeRequest) async throws -> CreatedResourceResponse {
        _ = orderId
        _ = serviceId
        _ = request
        throw APIError.serverError(501)
    }

    func createTire(orderId: String, serviceId: String, request: CreateTireRequest) async throws -> CreatedResourceResponse {
        _ = orderId
        _ = serviceId
        _ = request
        throw APIError.serverError(501)
    }

    func createPurchaseOrder(_ request: CreatePurchaseOrderRequest) async throws -> CreatePurchaseOrderResponse {
        _ = request
        throw APIError.serverError(501)
    }

    func fetchOpenPurchaseOrders() async throws -> [PurchaseOrderSummary] {
        throw APIError.serverError(501)
    }

    func fetchPurchaseOrder(id: String) async throws -> PurchaseOrderDetail {
        _ = id
        throw APIError.serverError(501)
    }

    func receivePurchaseOrderLineItem(
        purchaseOrderId: String,
        lineItemId: String,
        quantityReceived: Decimal?
    ) async throws -> PurchaseOrderDetail {
        _ = purchaseOrderId
        _ = lineItemId
        _ = quantityReceived
        throw APIError.serverError(501)
    }

    func fetchInventory() async throws -> [InventoryItem] {
        throw APIError.serverError(501)
    }

    func fetchOpenTickets() async throws -> [TicketModel] {
        throw APIError.serverError(501)
    }

    func fetchTicket(id: String) async throws -> TicketModel {
        _ = id
        throw APIError.serverError(501)
    }

    func addPartLineItem(
        toTicketId ticketId: String,
        sku: String?,
        partNumber: String?,
        description: String,
        quantity: Decimal,
        unitPrice: Decimal?
    ) async throws -> TicketLineItem {
        _ = ticketId
        _ = sku
        _ = partNumber
        _ = description
        _ = quantity
        _ = unitPrice
        throw APIError.serverError(501)
    }

    func runEndpointProbe() async throws -> ShopmonkeyEndpointProbeReport {
        throw APIError.serverError(501)
    }
}

public enum ProbeHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

public struct EndpointProbeResult: Hashable, Identifiable, Sendable {
    public var id: String { endpoint + "|" + method.rawValue }
    public let endpoint: String
    public let method: ProbeHTTPMethod
    public let statusCode: Int?
    public let supported: Bool
    public let hint: String
    public let responsePreview: String?

    public init(
        endpoint: String,
        method: ProbeHTTPMethod,
        statusCode: Int?,
        supported: Bool,
        hint: String,
        responsePreview: String?
    ) {
        self.endpoint = endpoint
        self.method = method
        self.statusCode = statusCode
        self.supported = supported
        self.hint = hint
        self.responsePreview = responsePreview
    }
}

public struct ShopmonkeyEndpointProbeReport: Hashable, Sendable {
    public let generatedAt: Date
    public let results: [EndpointProbeResult]

    public init(generatedAt: Date, results: [EndpointProbeResult]) {
        self.generatedAt = generatedAt
        self.results = results
    }

    public var createPurchaseOrderLikelySupported: Bool {
        let purchaseOrderListSupported = results.contains {
            $0.endpoint == "/purchase_order" && $0.method == .get && $0.supported
        }
        let purchaseOrderSearchSupported = results.contains {
            $0.endpoint == "/purchase_order/search" && $0.method == .post && $0.supported
        }
        return purchaseOrderListSupported || purchaseOrderSearchSupported
    }
}

private struct PurchaseOrderStatusSnapshot: Decodable {
    let status: String?
}

private enum PurchaseOrderStatusListOrSingle: Decodable {
    case single(PurchaseOrderStatusSnapshot)
    case list([PurchaseOrderStatusSnapshot])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([PurchaseOrderStatusSnapshot].self) {
            self = .list(list)
            return
        }

        if let wrapped = try? container.decode(DataWrapper<PurchaseOrderStatusSnapshot>.self) {
            self = .list(wrapped.data)
            return
        }

        if let wrapped = try? container.decode(ResultsWrapper<PurchaseOrderStatusSnapshot>.self) {
            self = .list(wrapped.results)
            return
        }

        self = .single(try container.decode(PurchaseOrderStatusSnapshot.self))
    }

    var values: [PurchaseOrderStatusSnapshot] {
        switch self {
        case .single(let one):
            return [one]
        case .list(let many):
            return many
        }
    }
}

private struct ListOrWrapped<T: Decodable>: Decodable {
    let values: [T]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([T].self) {
            values = list
            return
        }

        if let wrapped = try? container.decode(DataWrapper<T>.self) {
            values = wrapped.data
            return
        }

        if let wrapped = try? container.decode(ResultsWrapper<T>.self) {
            values = wrapped.results
            return
        }

        throw DecodingError.typeMismatch(
            [T].self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected an array or a wrapper object.")
        )
    }
}

private struct SingleOrWrapped<T: Decodable>: Decodable {
    let value: T

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let direct = try? container.decode(T.self) {
            value = direct
            return
        }

        if let wrappedData = try? container.decode(DataSingleWrapper<T>.self) {
            value = wrappedData.data
            return
        }

        if let wrappedResult = try? container.decode(ResultSingleWrapper<T>.self) {
            value = wrappedResult.result
            return
        }

        if let wrappedDataList = try? container.decode(DataWrapper<T>.self),
           let first = wrappedDataList.data.first {
            value = first
            return
        }

        if let wrappedResultsList = try? container.decode(ResultsWrapper<T>.self),
           let first = wrappedResultsList.results.first {
            value = first
            return
        }

        throw DecodingError.typeMismatch(
            T.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an object, wrapper object, or single-item wrapper array."
            )
        )
    }
}

private struct DataSingleWrapper<T: Decodable>: Decodable {
    let data: T
}

private struct ResultSingleWrapper<T: Decodable>: Decodable {
    let result: T
}

private struct DataWrapper<T: Decodable>: Decodable {
    let data: [T]
}

private struct ResultsWrapper<T: Decodable>: Decodable {
    let results: [T]
}

private struct InventoryPartSearchRequest: Encodable {
    let limit: Int
    let skip: Int
}

/// Shopmonkey sandbox API wrapper.
public struct ShopmonkeyAPI: ShopmonkeyServicing, Sendable {
    private let client: APIClient
    private let diagnosticsRecorder: NetworkDiagnosticsRecorder
    private let fallbackRecorder: any FallbackAnalyticsRecording

    public init(
        client: APIClient,
        fallbackRecorder: any FallbackAnalyticsRecording = NoopFallbackAnalyticsRecorder(),
        diagnosticsRecorder: NetworkDiagnosticsRecorder = .shared
    ) {
        self.client = client
        self.fallbackRecorder = fallbackRecorder
        self.diagnosticsRecorder = diagnosticsRecorder
    }

    // MARK: - Endpoints

    /// POST /vendor
    public func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        let url = try makeURL(path: "/vendor")
        let body = try APIClient.encodeJSON(request)
        let response: CreateVendorResponse = try await client.perform(.post, url: url, body: body)
        try validate(response)
        return response
    }

    /// POST /order/{orderId}/service/{serviceId}/part
    public func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
        let safeOrderId = orderId.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeServiceId = serviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeOrderId.isEmpty, !safeServiceId.isEmpty else {
            throw APIError.invalidURL
        }

        let url = try makeURL(path: "/order/\(safeOrderId)/service/\(safeServiceId)/part")
        let body = try APIClient.encodeJSON(request)
        let response: CreatePartResponse = try await client.perform(.post, url: url, body: body)
        try validate(response)
        return response
    }

    /// POST /order/{orderId}/service/{serviceId}/fee
    public func createFee(orderId: String, serviceId: String, request: CreateFeeRequest) async throws -> CreatedResourceResponse {
        let safeOrderId = orderId.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeServiceId = serviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeOrderId.isEmpty, !safeServiceId.isEmpty else {
            throw APIError.invalidURL
        }

        let url = try makeURL(path: "/order/\(safeOrderId)/service/\(safeServiceId)/fee")
        let body = try APIClient.encodeJSON(request)
        let response: CreatedResourceResponse = try await client.perform(.post, url: url, body: body)
        try validate(response)
        return response
    }

    /// POST /order/{orderId}/service/{serviceId}/tire
    public func createTire(orderId: String, serviceId: String, request: CreateTireRequest) async throws -> CreatedResourceResponse {
        let safeOrderId = orderId.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeServiceId = serviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeOrderId.isEmpty, !safeServiceId.isEmpty else {
            throw APIError.invalidURL
        }

        let url = try makeURL(path: "/order/\(safeOrderId)/service/\(safeServiceId)/tire")
        let body = try APIClient.encodeJSON(request)
        let response: CreatedResourceResponse = try await client.perform(.post, url: url, body: body)
        try validate(response)
        return response
    }

    /// POST /purchase_order
    public func createPurchaseOrder(_ request: CreatePurchaseOrderRequest) async throws -> CreatePurchaseOrderResponse {
        // Try canonical singular route first. Only use plural if singular route itself is unavailable.
        await fallbackRecorder.record(
            branch: FallbackBranch.submitPrimaryEndpoint,
            context: "POST /purchase_order"
        )
        do {
            return try await createPurchaseOrderOnRoute("/purchase_order", request: request)
        } catch let error as APIError {
            guard isRouteUnavailable(error) else {
                throw error
            }
        }

        // Tenant fallback: some deployments expose plural route only.
        await fallbackRecorder.record(
            branch: FallbackBranch.submitAlternateEndpoint,
            context: "POST /purchase_orders"
        )
        return try await createPurchaseOrderOnRoute("/purchase_orders", request: request)
    }

    /// GET /purchase_order
    public func getPurchaseOrders() async throws -> [PurchaseOrderResponse] {
        let url = try makeURL(path: "/purchase_order")
        let decoded: ListOrWrapped<PurchaseOrderResponse> = try await client.perform(.get, url: url)
        let values = decoded.values
        for po in values {
            try validate(po)
        }
        return values
    }

    /// GET /purchase_order
    /// Returns open purchase orders only (status-based filter, keeping unknown status entries).
    public func fetchOpenPurchaseOrders() async throws -> [PurchaseOrderSummary] {
        let allPurchaseOrders = try await getPurchaseOrders()
        return allPurchaseOrders
            .filter { isOpenPurchaseOrderStatus($0.status) }
            .map(mapPurchaseOrderSummary(from:))
    }

    /// GET /purchase_order/{id}
    public func fetchPurchaseOrder(id: String) async throws -> PurchaseOrderDetail {
        let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeID.isEmpty else {
            throw APIError.invalidURL
        }

        do {
            let url = try makeURL(path: "/purchase_order/\(safeID)")
            let decoded: SingleOrWrapped<PurchaseOrderResponse> = try await client.perform(.get, url: url)
            try validate(decoded.value)
            return mapPurchaseOrderDetail(from: decoded.value)
        } catch let apiError as APIError {
            if isRouteUnavailable(apiError) {
                let allPurchaseOrders = try await getPurchaseOrders()
                guard let matched = allPurchaseOrders.first(where: {
                    $0.id.trimmingCharacters(in: .whitespacesAndNewlines) == safeID
                }) else {
                    throw APIError.serverError(404)
                }
                return mapPurchaseOrderDetail(from: matched)
            }
            throw apiError
        }
    }

    /// POST receive endpoint candidates for purchase order line items.
    ///
    /// Contract notes:
    /// - We try line-level receive routes first and then PO-level receive routes.
    /// - If a route returns 404/405 (unavailable) or 400/422 (shape mismatch), we fallback to the next candidate.
    /// - If the receive response doesn't include a decodable PO payload, we fetch the PO detail as a canonical fallback.
    public func receivePurchaseOrderLineItem(
        purchaseOrderId: String,
        lineItemId: String,
        quantityReceived: Decimal?
    ) async throws -> PurchaseOrderDetail {
        let safePurchaseOrderID = purchaseOrderId.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeLineItemID = lineItemId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safePurchaseOrderID.isEmpty, !safeLineItemID.isEmpty else {
            throw APIError.invalidURL
        }

        let normalizedQuantity = quantityReceived.map { max(Decimal.zero, $0) }
        let lineRequest = ReceivePurchaseOrderLineItemRequest(
            lineItemId: safeLineItemID,
            quantityReceived: normalizedQuantity
        )
        let batchRequest = ReceivePurchaseOrderRequest(lineItems: [lineRequest])

        let lineRequestBody = try APIClient.encodeJSON(lineRequest)
        let batchRequestBody = try APIClient.encodeJSON(batchRequest)

        let attempts: [(path: String, body: Data)] = [
            ("/purchase_order/\(safePurchaseOrderID)/line_item/\(safeLineItemID)/receive", lineRequestBody),
            ("/purchase_order/\(safePurchaseOrderID)/part/\(safeLineItemID)/receive", lineRequestBody),
            ("/purchase_order/\(safePurchaseOrderID)/receive", batchRequestBody),
            ("/purchase_order/\(safePurchaseOrderID)/receiving", batchRequestBody)
        ]

        var lastRecoverableError: APIError?
        for attempt in attempts {
            do {
                let url = try makeURL(path: attempt.path)
                let payload: JSONValue = try await client.perform(.post, url: url, body: attempt.body)
                if let detail = mapPurchaseOrderDetailFromReceivePayload(payload) {
                    return detail
                }
                return try await fetchPurchaseOrder(id: safePurchaseOrderID)
            } catch let apiError as APIError {
                if isRouteUnavailable(apiError) || isValidationError(apiError) {
                    lastRecoverableError = apiError
                    continue
                }
                throw apiError
            }
        }

        if let lastRecoverableError {
            throw lastRecoverableError
        }
        throw APIError.serverError(501)
    }

    /// GET /order
    public func fetchOrders() async throws -> [OrderSummary] {
        let url = try makeURL(path: "/order")
        let decoded: ListOrWrapped<OrderSummary> = try await client.perform(.get, url: url)
        return decoded.values
    }

    /// GET /order/{orderId}/service
    public func fetchServices(orderId: String) async throws -> [ServiceSummary] {
        let safeOrderId = orderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeOrderId.isEmpty else {
            throw APIError.invalidURL
        }

        do {
            return try await fetchServicesFromServiceEndpoint(orderId: safeOrderId)
        } catch let error as APIError {
            if case .serverError(404) = error {
                return try await recoverServicesAfterNotFound(orderId: safeOrderId)
            }
            throw error
        }
    }

    /// GET /order
    /// Returns open tickets only (status-based filter, keeping unknown status entries).
    public func fetchOpenTickets() async throws -> [TicketModel] {
        let url = try makeURL(path: "/order")
        let decoded: ListOrWrapped<TicketEnvelope> = try await client.perform(.get, url: url)
        return decoded.values
            .map { $0.ticketModel(includeLineItems: false) }
            .filter { isOpenTicketStatus($0.status) }
    }

    /// GET /order/{id}
    public func fetchTicket(id: String) async throws -> TicketModel {
        let safeID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeID.isEmpty else {
            throw APIError.invalidURL
        }

        let url = try makeURL(path: "/order/\(safeID)")
        let decoded: SingleOrWrapped<TicketEnvelope> = try await client.perform(.get, url: url)
        return decoded.value.ticketModel(includeLineItems: true)
    }

    /// POST /order/{ticketId}/part
    public func addPartLineItem(
        toTicketId ticketId: String,
        sku: String?,
        partNumber: String?,
        description: String,
        quantity: Decimal,
        unitPrice: Decimal?
    ) async throws -> TicketLineItem {
        let safeTicketID = ticketId.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeTicketID.isEmpty, !safeDescription.isEmpty else {
            throw APIError.invalidURL
        }

        let safeQuantity = max(Decimal(1), quantity)
        let safeUnitPrice = unitPrice.map { max(Decimal.zero, $0) }
        let request = TicketPartLineItemCreateRequest(
            sku: normalizedOptionalString(sku),
            partNumber: normalizedOptionalString(partNumber),
            description: safeDescription,
            quantity: safeQuantity,
            unitPrice: safeUnitPrice
        )

        let url = try makeURL(path: "/order/\(safeTicketID)/part")
        let body = try APIClient.encodeJSON(request)
        let decoded: SingleOrWrapped<TicketPartLineItemCreateResponse> = try await client.perform(.post, url: url, body: body)
        return decoded.value.lineItem
    }

    /// POST /inventory_part/search
    public func fetchInventory() async throws -> [InventoryItem] {
        let request = InventoryPartSearchRequest(limit: 50, skip: 0)
        let url = try makeURL(path: "/inventory_part/search")
        let body = try APIClient.encodeJSON(request)
        let decoded: ListOrWrapped<InventoryItem> = try await client.perform(.post, url: url, body: body)
        return decoded.values
    }

    /// GET /vendor?search={name}
    public func searchVendors(name: String) async throws -> [VendorSummary] {
        let normalized = name.normalizedVendorName
        guard !normalized.isEmpty else {
            return []
        }

        do {
            let url = try makeURL(path: "/vendor", queryItems: [URLQueryItem(name: "search", value: normalized)])
            let decoded: ListOrWrapped<VendorSummary> = try await client.perform(.get, url: url)
            return rankVendorSearchResults(decoded.values, query: normalized)
        } catch let error as APIError {
            // If the sandbox doesn't support `search`, fall back to fetching vendors and filtering client-side.
            if case .serverError(let code) = error, (code == 400 || code == 404 || code == 405) {
                let url = try makeURL(path: "/vendor")
                let decoded: ListOrWrapped<VendorSummary> = try await client.perform(.get, url: url)
                return rankVendorSearchResults(decoded.values, query: normalized)
            }
            throw error
        }
    }

    /// Lightweight connectivity check used by Settings.
    /// - Important: Treats any 2xx as success and does not decode the response body.
    public func testConnection() async throws {
        let url = try makeURL(path: "/order")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let token = try await client.fetchBearerToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            await recordDiagnostics(
                request: request,
                statusCode: nil,
                responseData: nil,
                errorSummary: "No HTTP response"
            )
            throw APIError.serverError(-1)
        }

        await recordDiagnostics(
            request: request,
            statusCode: httpResponse.statusCode,
            responseData: data,
            errorSummary: nil
        )

        if (200...299).contains(httpResponse.statusCode) {
            return
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        if httpResponse.statusCode == 429 {
            throw APIError.rateLimited
        }

        throw APIError.serverError(httpResponse.statusCode)
    }

    /// Debug-only capability probe for sandbox endpoint discovery.
    /// Sends low-risk requests and reports status/body hints without exposing secrets.
    public func runEndpointProbe() async throws -> ShopmonkeyEndpointProbeReport {
        let probes: [(ProbeHTTPMethod, String, [String: String]?)] = [
            (.get, "/order", nil),
            (.get, "/purchase_order", nil),
            (.post, "/purchase_order/search", ["query": ""]),
            (.post, "/purchase_order/invalid/line_item/invalid/receive", ["line_item_id": "invalid", "quantity_received": "1"]),
            (.post, "/purchase_order/invalid/receive", ["line_items": "[]"]),
            (.post, "/order/invalid/service/invalid/part", ["name": "probe"]),
            (.post, "/order/invalid/service/invalid/fee", ["name": "probe"]),
            (.post, "/order/invalid/service/invalid/tire", ["name": "probe"])
        ]

        var results: [EndpointProbeResult] = []
        for probe in probes {
            let result = try await executeProbe(method: probe.0, path: probe.1, body: probe.2)
            results.append(result)
        }

        return ShopmonkeyEndpointProbeReport(generatedAt: Date(), results: results)
    }

    private func fetchServicesFromServiceEndpoint(orderId: String) async throws -> [ServiceSummary] {
        let url = try makeURL(path: "/order/\(orderId)/service")
        let decoded: ListOrWrapped<ServiceSummary> = try await client.perform(.get, url: url)
        return Self.normalizeServices(decoded.values)
    }

    private func recoverServicesAfterNotFound(orderId: String) async throws -> [ServiceSummary] {
        do {
            let orderDetail = try await fetchOrderDetailEnvelope(orderId: orderId)
            if !orderDetail.services.isEmpty {
                return Self.normalizeServices(orderDetail.services)
            }

            for alternateOrderID in orderDetail.alternateOrderIDs where alternateOrderID != orderId {
                do {
                    let resolved = try await fetchServicesFromServiceEndpoint(orderId: alternateOrderID)
                    if !resolved.isEmpty {
                        return resolved
                    }
                } catch let apiError as APIError {
                    if case .serverError(404) = apiError {
                        continue
                    }
                    throw apiError
                }
            }

            return []
        } catch let apiError as APIError {
            if case .serverError(404) = apiError {
                // Service lists are optional for some tickets/orders.
                return []
            }
            throw apiError
        }
    }

    private func fetchOrderDetailEnvelope(orderId: String) async throws -> OrderDetailEnvelope {
        let url = try makeURL(path: "/order/\(orderId)")
        let decoded: SingleOrWrapped<OrderDetailEnvelope> = try await client.perform(.get, url: url)
        return decoded.value
    }

    private static func normalizeServices(_ services: [ServiceSummary]) -> [ServiceSummary] {
        var normalized: [ServiceSummary] = []
        var seen: Set<String> = []

        for service in services {
            let trimmedID = service.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else { continue }

            let dedupeKey = trimmedID.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }

            let trimmedName = service.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.append(
                ServiceSummary(
                    id: trimmedID,
                    name: (trimmedName?.isEmpty == false) ? trimmedName : nil
                )
            )
        }

        return normalized
    }

    // MARK: - URL building

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let baseURL = ShopmonkeyBaseURL.sandboxV3

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }

        let endpointPath = path.hasPrefix("/") ? path : "/" + path
        components.path = baseURL.path + endpointPath
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        return url
    }

    private func rankVendorSearchResults(_ vendors: [VendorSummary], query: String) -> [VendorSummary] {
        let sanitized = vendors.filter { vendor in
            !vendor.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !vendor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let normalizedQuery = query.normalizedVendorName
        guard !normalizedQuery.isEmpty else { return [] }
        let minimumScore = 0.55

        var bestByNormalized: [String: (vendor: VendorSummary, score: Double)] = [:]
        for vendor in sanitized {
            let normalizedCandidate = vendor.name.normalizedVendorName
            guard !normalizedCandidate.isEmpty else { continue }

            let score = vendorMatchScore(query: normalizedQuery, candidate: normalizedCandidate)
            guard score >= minimumScore else { continue }

            if let existing = bestByNormalized[normalizedCandidate], existing.score >= score {
                continue
            }
            bestByNormalized[normalizedCandidate] = (vendor, score)
        }

        return bestByNormalized.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.vendor.name.localizedCaseInsensitiveCompare(rhs.vendor.name) == .orderedAscending
            }
            .map(\.vendor)
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func vendorMatchScore(query: String, candidate: String) -> Double {
        let normalizedQuery = query.normalizedVendorName
        let normalizedCandidate = candidate.normalizedVendorName
        guard !normalizedQuery.isEmpty, !normalizedCandidate.isEmpty else { return 0 }

        if normalizedQuery == normalizedCandidate {
            return 1.0
        }

        let canonicalQuery = canonicalVendorName(normalizedQuery)
        let canonicalCandidate = canonicalVendorName(normalizedCandidate)
        if !canonicalQuery.isEmpty, canonicalQuery == canonicalCandidate {
            return 0.96
        }

        var score = 0.0

        if normalizedCandidate.hasPrefix(normalizedQuery) || normalizedQuery.hasPrefix(normalizedCandidate) {
            score = max(score, 0.88)
        }

        if canonicalCandidate.hasPrefix(canonicalQuery) || canonicalQuery.hasPrefix(canonicalCandidate) {
            score = max(score, 0.84)
        }

        if normalizedCandidate.contains(normalizedQuery) || normalizedQuery.contains(normalizedCandidate) {
            score = max(score, 0.66)
        }

        let queryTokens = Set(canonicalQuery.split(separator: " ").map(String.init))
        let candidateTokens = Set(canonicalCandidate.split(separator: " ").map(String.init))
        if !queryTokens.isEmpty, !candidateTokens.isEmpty {
            let overlap = queryTokens.intersection(candidateTokens).count
            if overlap > 0 {
                let denominator = max(queryTokens.count, candidateTokens.count)
                let tokenScore = Double(overlap) / Double(denominator)
                score = max(score, 0.55 + (tokenScore * 0.35))
            }
        }

        return min(1.0, score)
    }

    private func canonicalVendorName(_ raw: String) -> String {
        let normalized = raw.normalizedVendorName
        guard !normalized.isEmpty else { return "" }

        var tokens = normalized.split(separator: " ").map(String.init)
        while tokens.count > 1, let tail = tokens.last, legalSuffixes.contains(tail) {
            tokens.removeLast()
        }

        return tokens.joined(separator: " ")
    }

    private var legalSuffixes: Set<String> {
        [
            "inc",
            "incorporated",
            "llc",
            "ltd",
            "limited",
            "co",
            "corp",
            "corporation",
            "company",
            "plc"
        ]
    }

    private func isOpenTicketStatus(_ status: String?) -> Bool {
        guard let status else { return true }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        let closedStatuses: Set<String> = [
            "closed",
            "complete",
            "completed",
            "paid",
            "cancelled",
            "canceled",
            "archived"
        ]
        return !closedStatuses.contains(normalized)
    }

    private func executeProbe(method: ProbeHTTPMethod, path: String, body: [String: String]?) async throws -> EndpointProbeResult {
        let url = try makeURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = try APIClient.encodeJSON(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let token = try await client.fetchBearerToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            await recordDiagnostics(
                request: request,
                statusCode: nil,
                responseData: data,
                errorSummary: "No HTTP response"
            )
            return EndpointProbeResult(
                endpoint: path,
                method: method,
                statusCode: nil,
                supported: false,
                hint: "No HTTP response.",
                responsePreview: nil
            )
        }

        let hint = probeHint(for: http.statusCode)
        let supported = isLikelySupported(statusCode: http.statusCode)
        let preview = sanitizedPreview(from: data)

        await recordDiagnostics(
            request: request,
            statusCode: http.statusCode,
            responseData: data,
            errorSummary: nil
        )

        #if DEBUG
        print("[EndpointProbe] \(method.rawValue) \(path) -> \(http.statusCode)")
        if let preview {
            print("[EndpointProbe] Body: \(preview)")
        }
        #endif

        return EndpointProbeResult(
            endpoint: path,
            method: method,
            statusCode: http.statusCode,
            supported: supported,
            hint: hint,
            responsePreview: preview
        )
    }

    private func isLikelySupported(statusCode: Int) -> Bool {
        switch statusCode {
        case 200...299:
            return true
        case 400, 401, 403, 422, 429:
            // Route likely exists; request rejected by validation/auth/rate limit.
            return true
        default:
            return false
        }
    }

    private func probeHint(for statusCode: Int) -> String {
        switch statusCode {
        case 200...299:
            return "Endpoint reachable."
        case 400:
            return "Bad request; route likely exists."
        case 401:
            return "Unauthorized; verify API key scope."
        case 403:
            return "Forbidden; route may require additional permissions."
        case 404:
            return "Not found; route likely unavailable."
        case 405:
            return "Method not allowed; route exists but method differs."
        case 422:
            return "Validation failed; route likely exists."
        case 429:
            return "Rate limited."
        default:
            return "HTTP \(statusCode)."
        }
    }

    private func sanitizedPreview(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        // Preserve enough detail for endpoint debugging while still capping runaway payloads.
        return String(raw.prefix(4_000))
    }

    private func recordDiagnostics(
        request: URLRequest,
        statusCode: Int?,
        responseData: Data?,
        errorSummary: String?
    ) async {
        await diagnosticsRecorder.record(
            NetworkDiagnosticsEntry(
                method: request.httpMethod ?? "GET",
                url: request.url?.absoluteString ?? "(unknown url)",
                statusCode: statusCode,
                requestBodyPreview: request.httpBody.flatMap(sanitizedPreview(from:)),
                responseBodyPreview: responseData.flatMap(sanitizedPreview(from:)),
                errorSummary: errorSummary
            )
        )
    }

    private func postPurchaseOrder(
        path: String,
        body request: CreatePurchaseOrderRequest,
        costMode: PurchaseOrderCostMode,
        bodyMode: PurchaseOrderBodyMode
    ) async throws -> CreatePurchaseOrderResponse {
        let url = try makeURL(path: path)
        let body = try makePurchaseOrderBodyData(request: request, costMode: costMode, bodyMode: bodyMode)
        let response: CreatePurchaseOrderResponse = try await client.perform(.post, url: url, body: body)
        try validate(response)
        return response
    }

    private func createPurchaseOrderOnRoute(
        _ path: String,
        request: CreatePurchaseOrderRequest
    ) async throws -> CreatePurchaseOrderResponse {
        var lastValidationError: APIError?
        var statusesToTry = purchaseOrderStatusCandidates(
            startingWith: request.status,
            additional: await discoverLivePurchaseOrderStatuses()
        )
        var queuedKeys = Set(statusesToTry.map(statusCandidateKey))
        var didLoadFailureDerivedStatuses = false
        var index = 0

        statusLoop: while index < statusesToTry.count {
            let status = statusesToTry[index]
            index += 1
            let requestForStatus = request.withStatus(status)
            let bodyModes = purchaseOrderBodyModes(for: requestForStatus)

            for bodyMode in bodyModes {
                do {
                    let response = try await postPurchaseOrder(
                        path: path,
                        body: requestForStatus,
                        costMode: .centsFirst,
                        bodyMode: bodyMode
                    )
                    persistPreferredPurchaseOrderStatus(status)
                    return response
                } catch let firstError as APIError {
                    guard isValidationError(firstError) else {
                        throw firstError
                    }

                    // When status is invalid, skip cost/body compatibility retries and move to next status.
                    if await isStatusValidationFailure(for: path) {
                        await fallbackRecorder.record(
                            branch: FallbackBranch.submitStatusFallback,
                            context: "Status fallback on \(path)"
                        )
                        lastValidationError = firstError
                        if let status,
                           statusCandidateKey(status) == statusCandidateKey(preferredPurchaseOrderStatus()) {
                            persistPreferredPurchaseOrderStatus(nil)
                        }
                        if !didLoadFailureDerivedStatuses {
                            didLoadFailureDerivedStatuses = true
                            let additionalStatuses = await additionalStatusCandidates(for: path)
                            appendStatusCandidates(
                                additionalStatuses,
                                to: &statusesToTry,
                                queuedKeys: &queuedKeys,
                                insertionIndex: index
                            )
                        }
                        continue statusLoop
                    }

                    do {
                        // If cents-based cost keys are not accepted, retry same status with unit_cost-focused body.
                        let response = try await postPurchaseOrder(
                            path: path,
                            body: requestForStatus,
                            costMode: .unitCostFirst,
                            bodyMode: bodyMode
                        )
                        persistPreferredPurchaseOrderStatus(status)
                        return response
                    } catch let secondError as APIError {
                        guard isValidationError(secondError) else {
                            throw secondError
                        }

                        lastValidationError = secondError

                        // Status validation errors should immediately rotate to another status candidate.
                        if await isStatusValidationFailure(for: path) {
                            await fallbackRecorder.record(
                                branch: FallbackBranch.submitStatusFallback,
                                context: "Status fallback on \(path)"
                            )
                            if let status,
                               statusCandidateKey(status) == statusCandidateKey(preferredPurchaseOrderStatus()) {
                                persistPreferredPurchaseOrderStatus(nil)
                            }
                            if !didLoadFailureDerivedStatuses {
                                didLoadFailureDerivedStatuses = true
                                let additionalStatuses = await additionalStatusCandidates(for: path)
                                appendStatusCandidates(
                                    additionalStatuses,
                                    to: &statusesToTry,
                                    queuedKeys: &queuedKeys,
                                    insertionIndex: index
                                )
                            }
                            continue statusLoop
                        }

                        let isLastBodyMode = bodyMode == bodyModes.last

                        // Try another body mode first; only evaluate status fallbacks when modes are exhausted.
                        if !isLastBodyMode {
                            continue
                        }
                        throw secondError
                    }
                }
            }
        }

        await fallbackRecorder.record(
            branch: FallbackBranch.submitFallbackExhausted,
            context: "Exhausted fallback on \(path)"
        )
        throw lastValidationError ?? APIError.serverError(400)
    }

    private enum PurchaseOrderCostMode {
        case centsFirst
        case unitCostFirst
    }

    private enum PurchaseOrderBodyMode: Equatable {
        case typedCollectionsOnly
        case combined
    }

    private func purchaseOrderBodyModes(for request: CreatePurchaseOrderRequest) -> [PurchaseOrderBodyMode] {
        let hasTypedCollections = !request.parts.isEmpty || !request.fees.isEmpty || !request.tires.isEmpty
        if hasTypedCollections {
            return [.typedCollectionsOnly, .combined]
        }
        return [.combined]
    }

    private func makePurchaseOrderBodyData(
        request: CreatePurchaseOrderRequest,
        costMode: PurchaseOrderCostMode,
        bodyMode: PurchaseOrderBodyMode
    ) throws -> Data {
        let lineItemsJSON = request.lineItems.map { makeLineItemJSON($0, costMode: costMode) }
        var json: [String: Any] = [
            "vendor_id": request.vendorId,
            "vendorId": request.vendorId,
            "parts": request.parts.map { makePartJSON($0, costMode: costMode, vendorId: request.vendorId) },
            "fees": request.fees.map { makeFeeJSON($0) },
            "tires": request.tires.map { makeTireJSON($0, costMode: costMode, vendorId: request.vendorId) }
        ]

        if bodyMode == .combined {
            json["line_items"] = lineItemsJSON
            json["lineItems"] = lineItemsJSON
        }

        if let invoiceNumber = request.invoiceNumber, !invoiceNumber.isEmpty {
            json["invoice_number"] = invoiceNumber
            json["invoiceNumber"] = invoiceNumber
        }

        if let notes = request.notes, !notes.isEmpty {
            json["notes"] = notes
            json["note"] = notes
        }

        if let purchaseOrderId = request.purchaseOrderId, !purchaseOrderId.isEmpty {
            // Some tenants accept explicit PO identifiers when appending to a draft PO.
            json["purchase_order_id"] = purchaseOrderId
            json["purchaseOrderId"] = purchaseOrderId
            json["id"] = purchaseOrderId
        }

        if let orderId = request.orderId, !orderId.isEmpty {
            json["order_id"] = orderId
            json["orderId"] = orderId
        }

        if let status = request.status, !status.isEmpty {
            json["status"] = status
        }

        do {
            return try JSONSerialization.data(withJSONObject: json, options: [])
        } catch {
            throw APIError.encodingFailed
        }
    }

    private func makeLineItemJSON(_ item: CreatePurchaseOrderLineItemRequest, costMode: PurchaseOrderCostMode) -> [String: Any] {
        var json: [String: Any] = [
            "description": item.description,
            "name": item.name ?? item.description,
            "quantity": item.quantity
        ]

        if let partNumber = item.partNumber, !partNumber.isEmpty {
            json["part_number"] = partNumber
            json["partNumber"] = partNumber
            json["number"] = partNumber
        }

        let unitCostDecimal = item.unitCost ?? (Decimal(item.unitCostCents) / 100)
        let unitCostNumber = NSDecimalNumber(decimal: unitCostDecimal)
        let resolvedCostCents = item.costCents ?? item.unitCostCents
        let lineTotalCents = max(item.quantity, 1) * resolvedCostCents

        switch costMode {
        case .centsFirst:
            json["unit_cost_cents"] = item.unitCostCents
            json["unitCostCents"] = item.unitCostCents
            json["cost_cents"] = resolvedCostCents
            json["costCents"] = resolvedCostCents
            json["unit_cost"] = unitCostNumber
            json["unitCost"] = unitCostNumber
        case .unitCostFirst:
            json["unit_cost"] = unitCostNumber
            json["unitCost"] = unitCostNumber
            json["unit_cost_cents"] = item.unitCostCents
            json["unitCostCents"] = item.unitCostCents
            json["cost_cents"] = resolvedCostCents
            json["costCents"] = resolvedCostCents
        }

        // Compatibility aliases observed in tenant-specific write schemas.
        json["cost"] = unitCostNumber
        json["price"] = unitCostNumber
        json["line_total_cents"] = lineTotalCents
        json["lineTotalCents"] = lineTotalCents

        return json
    }

    private func makePartJSON(
        _ item: CreatePurchaseOrderPartRequest,
        costMode: PurchaseOrderCostMode,
        vendorId: String
    ) -> [String: Any] {
        var json: [String: Any] = [
            "name": item.name,
            "description": item.description ?? item.name,
            "quantity": item.quantity,
            "vendor_id": vendorId,
            "vendorId": vendorId
        ]

        if let number = item.number, !number.isEmpty {
            json["number"] = number
        }

        if let partNumber = item.partNumber, !partNumber.isEmpty {
            json["part_number"] = partNumber
            json["partNumber"] = partNumber
        }

        let unitCostDecimal = Decimal(item.costCents) / 100
        let unitCostNumber = NSDecimalNumber(decimal: unitCostDecimal)

        switch costMode {
        case .centsFirst:
            json["cost_cents"] = item.costCents
            json["costCents"] = item.costCents
            json["unit_cost_cents"] = item.costCents
            json["unitCostCents"] = item.costCents
            json["unit_cost"] = unitCostNumber
            json["unitCost"] = unitCostNumber
        case .unitCostFirst:
            json["unit_cost"] = unitCostNumber
            json["unitCost"] = unitCostNumber
            json["cost_cents"] = item.costCents
            json["costCents"] = item.costCents
            json["unit_cost_cents"] = item.costCents
            json["unitCostCents"] = item.costCents
        }

        // Compatibility aliases observed in tenant-specific write schemas.
        json["cost"] = unitCostNumber
        json["price"] = unitCostNumber
        json["wholesale_cost_cents"] = item.costCents
        json["wholesaleCostCents"] = item.costCents

        return json
    }

    private func makeFeeJSON(_ item: CreatePurchaseOrderFeeRequest) -> [String: Any] {
        let amountNumber = NSDecimalNumber(decimal: Decimal(item.amountCents) / 100)
        let json: [String: Any] = [
            "name": item.name,
            "description": item.description ?? item.name,
            "amount_cents": item.amountCents,
            "amountCents": item.amountCents,
            "amount": amountNumber,
            "cost_cents": item.amountCents,
            "costCents": item.amountCents,
            "cost": amountNumber
        ]
        return json
    }

    private func makeTireJSON(
        _ item: CreatePurchaseOrderTireRequest,
        costMode: PurchaseOrderCostMode,
        vendorId: String
    ) -> [String: Any] {
        var json: [String: Any] = [
            "name": item.name,
            "description": item.description ?? item.name,
            "quantity": item.quantity,
            "vendor_id": vendorId,
            "vendorId": vendorId
        ]

        if let number = item.number, !number.isEmpty {
            json["number"] = number
        }

        if let partNumber = item.partNumber, !partNumber.isEmpty {
            json["part_number"] = partNumber
            json["partNumber"] = partNumber
        }

        let unitCostDecimal = Decimal(item.costCents) / 100
        let unitCostNumber = NSDecimalNumber(decimal: unitCostDecimal)

        switch costMode {
        case .centsFirst:
            json["cost_cents"] = item.costCents
            json["costCents"] = item.costCents
            json["unit_cost_cents"] = item.costCents
            json["unitCostCents"] = item.costCents
            json["unit_cost"] = unitCostNumber
            json["unitCost"] = unitCostNumber
        case .unitCostFirst:
            json["unit_cost"] = unitCostNumber
            json["unitCost"] = unitCostNumber
            json["cost_cents"] = item.costCents
            json["costCents"] = item.costCents
            json["unit_cost_cents"] = item.costCents
            json["unitCostCents"] = item.costCents
        }

        // Compatibility aliases observed in tenant-specific write schemas.
        json["cost"] = unitCostNumber
        json["price"] = unitCostNumber

        return json
    }

    private func isRouteUnavailable(_ error: APIError) -> Bool {
        if case .serverError(let code) = error {
            return code == 404 || code == 405
        }
        return false
    }

    private func isValidationError(_ error: APIError) -> Bool {
        if case .serverError(let code) = error {
            return code == 400 || code == 422
        }
        return false
    }

    private func purchaseOrderStatusCandidates(
        startingWith initial: String?,
        additional: [String] = []
    ) -> [String?] {
        let defaults = ["draft", "open", "pending", "submitted"]

        var seen = Set<String>()
        var ordered: [String?] = []

        func append(_ status: String?) {
            guard let status else {
                if !ordered.contains(where: { $0 == nil }) {
                    ordered.append(nil)
                }
                return
            }

            let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !seen.contains(trimmed) else { return }

            seen.insert(trimmed)
            ordered.append(trimmed)
        }

        append(initial)
        append(preferredPurchaseOrderStatus())
        // Let server default if explicit status fails.
        append(nil)

        for status in additional {
            append(status)
        }

        for status in defaults {
            append(status)
        }

        return ordered
    }

    private func statusCandidateKey(_ status: String?) -> String {
        guard let status else { return "<nil>" }
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "<nil>" : trimmed
    }

    private func appendStatusCandidates(
        _ additions: [String],
        to statuses: inout [String?],
        queuedKeys: inout Set<String>,
        insertionIndex: Int? = nil
    ) {
        var insertAt = insertionIndex ?? statuses.count
        for status in additions {
            let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = statusCandidateKey(trimmed)
            guard !queuedKeys.contains(key) else { continue }

            queuedKeys.insert(key)
            if insertAt >= statuses.count {
                statuses.append(trimmed)
                insertAt = statuses.count
            } else {
                statuses.insert(trimmed, at: insertAt)
                insertAt += 1
            }
        }
    }

    private func isStatusValidationFailure(for path: String) async -> Bool {
        guard let failure = await diagnosticsRecorder.latestFailure(urlContains: path, method: "POST") else {
            return false
        }

        let haystack = [
            failure.errorSummary,
            failure.responseBodyPreview
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return haystack.contains("body/status")
            || (haystack.contains("status") && haystack.contains("allowed"))
            || haystack.contains("invalid status")
    }

    private func additionalStatusCandidates(for path: String) async -> [String] {
        var discovered: [String] = []

        if let failure = await diagnosticsRecorder.latestFailure(urlContains: path, method: "POST") {
            if let response = failure.responseBodyPreview {
                discovered.append(contentsOf: parseStatusCandidates(from: response))
            }
            if let summary = failure.errorSummary {
                discovered.append(contentsOf: parseStatusCandidates(from: summary))
            }
        }

        discovered.append(contentsOf: await discoverLivePurchaseOrderStatuses())

        var seen = Set<String>()
        var ordered: [String] = []
        for raw in discovered {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(trimmed)
        }
        return ordered
    }

    private func parseStatusCandidates(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            guard let cleaned = cleanedStatusCandidate(from: raw) else { return }
            let key = cleaned
            guard !seen.contains(key) else { return }
            seen.insert(key)
            candidates.append(cleaned)
        }

        if let quotedRegex = try? NSRegularExpression(pattern: #""([^"]+)""#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in quotedRegex.matches(in: text, range: range) {
                guard let candidateRange = Range(match.range(at: 1), in: text) else { continue }
                append(String(text[candidateRange]))
            }
        }

        if let allowedRegex = try? NSRegularExpression(pattern: #"(?i)allowed values[^[]*\[([^\]]+)\]"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in allowedRegex.matches(in: text, range: range) {
                guard let candidateRange = Range(match.range(at: 1), in: text) else { continue }
                let rawList = text[candidateRange]
                rawList.split(separator: ",").forEach { token in
                    append(String(token))
                }
            }
        }

        return candidates
    }

    private func cleanedStatusCandidate(from raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'[]{}()"))

        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let blockedTokens: Set<String> = [
            "success",
            "message",
            "error",
            "statuscode",
            "status",
            "post",
            "route",
            "http",
            "not found",
            "true",
            "false"
        ]

        guard !blockedTokens.contains(lower) else { return nil }
        guard !lower.contains("allowed values") else { return nil }
        guard !lower.contains("must be") else { return nil }
        guard !lower.contains("purchase_order") else { return nil }
        guard !trimmed.contains("/") else { return nil }
        guard trimmed.range(of: #"^[A-Za-z0-9 _-]{1,40}$"#, options: .regularExpression) != nil else {
            return nil
        }

        return trimmed
    }

    private func discoverLivePurchaseOrderStatuses() async -> [String] {
        guard let url = try? makeURL(path: "/purchase_order") else {
            return []
        }

        do {
            let decoded: PurchaseOrderStatusListOrSingle = try await client.perform(.get, url: url)
            let raw = decoded.values.compactMap { $0.status }
            var seen = Set<String>()
            var ordered: [String] = []

            for status in raw {
                let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let key = trimmed
                guard !seen.contains(key) else { continue }

                seen.insert(key)
                ordered.append(trimmed)
            }

            return ordered
        } catch {
            return []
        }
    }

    private func preferredPurchaseOrderStatus() -> String? {
        let value = UserDefaults.standard.string(forKey: purchaseOrderStatusPreferenceKey)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistPreferredPurchaseOrderStatus(_ status: String?) {
        let defaults = UserDefaults.standard
        guard let status else {
            defaults.removeObject(forKey: purchaseOrderStatusPreferenceKey)
            return
        }

        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            defaults.removeObject(forKey: purchaseOrderStatusPreferenceKey)
            return
        }
        defaults.set(trimmed, forKey: purchaseOrderStatusPreferenceKey)
    }

    private var purchaseOrderStatusPreferenceKey: String { "shopmonkey.preferred_po_status" }

    private func isOpenPurchaseOrderStatus(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        let closedStatuses: Set<String> = [
            "closed",
            "completed",
            "complete",
            "cancelled",
            "canceled",
            "received",
            "archived"
        ]
        return !closedStatuses.contains(normalized)
    }

    private func mapPurchaseOrderSummary(from response: PurchaseOrderResponse) -> PurchaseOrderSummary {
        PurchaseOrderSummary(
            id: response.id,
            vendorName: normalizedOptionalString(response.vendorName),
            status: normalizedOptionalString(response.status),
            createdAt: nil,
            updatedAt: nil,
            totalLineCount: response.allLineItems.count
        )
    }

    private func mapPurchaseOrderDetail(from response: PurchaseOrderResponse) -> PurchaseOrderDetail {
        PurchaseOrderDetail(
            id: response.id,
            vendorName: normalizedOptionalString(response.vendorName),
            status: normalizedOptionalString(response.status),
            createdAt: nil,
            updatedAt: nil,
            lineItems: mapPurchaseOrderLineItems(from: response)
        )
    }

    private func mapPurchaseOrderLineItems(from response: PurchaseOrderResponse) -> [PurchaseOrderLineItem] {
        response.allLineItems.enumerated().map { index, lineItem in
            let safeQuantity = max(0, lineItem.quantity)
            let quantityOrdered = Decimal(safeQuantity)
            let quantityReceived = lineItem.quantityReceived.map { Decimal(max(0, $0)) }
            let unitCost = Decimal(max(0, lineItem.costCents)) / 100
            let extendedCost = unitCost * quantityOrdered
            return PurchaseOrderLineItem(
                id: normalizedOptionalString(lineItem.id) ?? "\(response.id)_\(lineItem.kind.rawValue)_\(index)",
                kind: lineItem.kind.rawValue,
                sku: normalizedOptionalString(lineItem.sku),
                partNumber: normalizedOptionalString(lineItem.partNumber),
                description: lineItem.name,
                quantityOrdered: quantityOrdered,
                quantityReceived: quantityReceived,
                unitCost: unitCost,
                extendedCost: extendedCost
            )
        }
    }

    private func mapPurchaseOrderDetailFromReceivePayload(_ payload: JSONValue) -> PurchaseOrderDetail? {
        if let decoded = decodePurchaseOrderResponse(from: payload) {
            return mapPurchaseOrderDetail(from: decoded)
        }

        if case .object(let object) = payload {
            let envelopeKeys = ["data", "result", "purchase_order", "purchaseOrder", "response", "order"]
            for key in envelopeKeys {
                guard let nested = object.first(where: { $0.key.lowercased() == key.lowercased() })?.value else {
                    continue
                }
                if let decoded = decodePurchaseOrderResponse(from: nested) {
                    return mapPurchaseOrderDetail(from: decoded)
                }
            }
        }

        return nil
    }

    private func decodePurchaseOrderResponse(from value: JSONValue) -> PurchaseOrderResponse? {
        guard let data = makeJSONData(from: value) else {
            return nil
        }
        return try? JSONDecoder().decode(PurchaseOrderResponse.self, from: data)
    }

    private func makeJSONData(from value: JSONValue) -> Data? {
        guard let object = makeJSONObject(from: value),
              JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    private func makeJSONObject(from value: JSONValue) -> Any? {
        switch value {
        case .object(let object):
            var dictionary: [String: Any] = [:]
            for (key, nested) in object {
                dictionary[key] = makeJSONObject(from: nested) ?? NSNull()
            }
            return dictionary

        case .array(let values):
            return values.map { makeJSONObject(from: $0) ?? NSNull() }

        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    // MARK: - Response validation

    private func validate(_ response: CreateVendorResponse) throws {
        guard !response.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decodingFailed
        }
        guard !response.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decodingFailed
        }
    }

    private func validate(_ response: CreatePartResponse) throws {
        guard !response.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decodingFailed
        }
        guard !response.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decodingFailed
        }
    }

    private func validate(_ response: CreatedResourceResponse) throws {
        guard !response.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decodingFailed
        }
    }

    private func validate(_ response: CreatePurchaseOrderResponse) throws {
        guard !response.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decodingFailed
        }
    }

    private func validate(_ response: PurchaseOrderResponse) throws {
        guard !response.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decodingFailed
        }
    }
}

// MARK: - DTOs (strict)

public struct CreateVendorRequest: Encodable, Sendable {
    public let name: String
    public let phone: String?
    public let email: String?
    public let notes: String?

    public init(
        name: String,
        phone: String? = nil,
        email: String? = nil,
        notes: String? = nil
    ) {
        self.name = name
        self.phone = phone
        self.email = email
        self.notes = notes
    }
}

public struct CreateVendorResponse: Decodable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let root = try JSONValue(from: decoder)

        // If server explicitly returns success=false, treat as invalid success payload.
        if let success = Self.firstBool(keys: ["success"], in: root), success == false {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Create vendor payload indicates failure.")
            )
        }

        let resolvedID = Self.firstString(
            keys: ["id", "vendor_id", "vendorId"],
            in: root
        )
        let resolvedName = Self.firstString(
            keys: ["name", "vendor_name", "vendorName"],
            in: root
        )

        self.id = resolvedID ?? ""
        self.name = resolvedName ?? ""
    }

    private static func firstString(keys: [String], in value: JSONValue) -> String? {
        let lookup = Set(keys.map { $0.lowercased() })
        return firstString(matching: lookup, in: value)
    }

    private static func firstString(matching keys: Set<String>, in value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            for (rawKey, candidate) in object {
                if keys.contains(rawKey.lowercased()),
                   let scalar = scalarString(from: candidate),
                   !scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return scalar
                }
            }

            // Prefer common envelope keys before recursive fallback scan.
            let envelopeKeys = ["data", "result", "vendor", "response"]
            for key in envelopeKeys {
                if let nested = object[key],
                   let found = firstString(matching: keys, in: nested) {
                    return found
                }
            }

            for nested in object.values {
                if let found = firstString(matching: keys, in: nested) {
                    return found
                }
            }
            return nil

        case .array(let values):
            for nested in values {
                if let found = firstString(matching: keys, in: nested) {
                    return found
                }
            }
            return nil

        default:
            return nil
        }
    }

    private static func firstBool(keys: [String], in value: JSONValue) -> Bool? {
        let lookup = Set(keys.map { $0.lowercased() })
        return firstBool(matching: lookup, in: value)
    }

    private static func firstBool(matching keys: Set<String>, in value: JSONValue) -> Bool? {
        switch value {
        case .object(let object):
            for (rawKey, candidate) in object {
                if keys.contains(rawKey.lowercased()),
                   let scalar = scalarBool(from: candidate) {
                    return scalar
                }
            }

            for nested in object.values {
                if let found = firstBool(matching: keys, in: nested) {
                    return found
                }
            }
            return nil

        case .array(let values):
            for nested in values {
                if let found = firstBool(matching: keys, in: nested) {
                    return found
                }
            }
            return nil

        default:
            return nil
        }
    }

    private static func scalarString(from value: JSONValue) -> String? {
        switch value {
        case .string(let raw):
            return raw
        case .int(let raw):
            return String(raw)
        case .double(let raw):
            return String(raw)
        case .bool(let raw):
            return raw ? "true" : "false"
        case .null, .object, .array:
            return nil
        }
    }

    private static func scalarBool(from value: JSONValue) -> Bool? {
        switch value {
        case .bool(let raw):
            return raw
        case .string(let raw):
            let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower == "true" { return true }
            if lower == "false" { return false }
            return nil
        case .int(let raw):
            if raw == 1 { return true }
            if raw == 0 { return false }
            return nil
        case .double(let raw):
            if raw == 1 { return true }
            if raw == 0 { return false }
            return nil
        case .null, .object, .array:
            return nil
        }
    }
}

public struct CreatePartRequest: Encodable, Sendable {
    public let name: String
    public let quantity: Int
    public let partNumber: String?
    public let wholesaleCostCents: Int
    public let vendorId: String
    public let purchaseOrderId: String?

    public init(
        name: String,
        quantity: Int,
        partNumber: String?,
        wholesaleCostCents: Int,
        vendorId: String,
        purchaseOrderId: String?
    ) {
        self.name = name
        self.quantity = quantity
        self.partNumber = partNumber
        self.wholesaleCostCents = wholesaleCostCents
        self.vendorId = vendorId
        self.purchaseOrderId = purchaseOrderId
    }

    enum CodingKeys: String, CodingKey {
        case name
        case quantity
        case partNumber = "part_number"
        case wholesaleCostCents = "wholesale_cost_cents"
        case vendorId = "vendor_id"
        case purchaseOrderId = "purchase_order_id"
    }
}

public struct CreatePartResponse: Decodable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct CreateFeeRequest: Encodable, Sendable {
    public let description: String
    public let amountCents: Int
    public let purchaseOrderId: String?

    public init(description: String, amountCents: Int, purchaseOrderId: String?) {
        self.description = description
        self.amountCents = amountCents
        self.purchaseOrderId = purchaseOrderId
    }

    enum CodingKeys: String, CodingKey {
        case description
        case amountCents = "amount_cents"
        case purchaseOrderId = "purchase_order_id"
    }
}

public struct CreateTireRequest: Encodable, Sendable {
    public let description: String
    public let quantity: Int
    public let costCents: Int
    public let vendorId: String?
    public let purchaseOrderId: String?

    public init(
        description: String,
        quantity: Int,
        costCents: Int,
        vendorId: String?,
        purchaseOrderId: String?
    ) {
        self.description = description
        self.quantity = quantity
        self.costCents = costCents
        self.vendorId = vendorId
        self.purchaseOrderId = purchaseOrderId
    }

    enum CodingKeys: String, CodingKey {
        case description
        case quantity
        case costCents = "cost_cents"
        case vendorId = "vendor_id"
        case purchaseOrderId = "purchase_order_id"
    }
}

public struct CreatePurchaseOrderLineItemRequest: Encodable, Hashable, Sendable {
    public let description: String
    public let quantity: Int
    public let unitCostCents: Int
    public let name: String?
    public let partNumber: String?
    public let costCents: Int?
    public let unitCost: Decimal?

    public init(
        description: String,
        quantity: Int,
        unitCostCents: Int,
        name: String? = nil,
        partNumber: String? = nil,
        costCents: Int? = nil,
        unitCost: Decimal? = nil
    ) {
        self.description = description
        self.quantity = quantity
        self.unitCostCents = unitCostCents
        self.name = name
        self.partNumber = partNumber
        self.costCents = costCents
        self.unitCost = unitCost
    }

    enum CodingKeys: String, CodingKey {
        case description
        case quantity
        case unitCostCents = "unit_cost_cents"
        case name
        case partNumber = "part_number"
        case costCents = "cost_cents"
        case unitCost = "unit_cost"
    }
}

public struct CreatePurchaseOrderPartRequest: Encodable, Hashable, Sendable {
    public let name: String
    public let quantity: Int
    public let costCents: Int
    public let number: String?
    public let description: String?
    public let partNumber: String?

    public init(
        name: String,
        quantity: Int,
        costCents: Int,
        number: String?,
        description: String?,
        partNumber: String?
    ) {
        self.name = name
        self.quantity = quantity
        self.costCents = costCents
        self.number = number
        self.description = description
        self.partNumber = partNumber
    }

    enum CodingKeys: String, CodingKey {
        case name
        case quantity
        case costCents = "cost_cents"
        case number
        case description
        case partNumber = "part_number"
    }
}

public struct CreatePurchaseOrderFeeRequest: Encodable, Hashable, Sendable {
    public let name: String
    public let amountCents: Int
    public let description: String?

    public init(name: String, amountCents: Int, description: String?) {
        self.name = name
        self.amountCents = amountCents
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case name
        case amountCents = "amount_cents"
        case description
    }
}

public struct CreatePurchaseOrderTireRequest: Encodable, Hashable, Sendable {
    public let name: String
    public let quantity: Int
    public let costCents: Int
    public let number: String?
    public let description: String?
    public let partNumber: String?

    public init(
        name: String,
        quantity: Int,
        costCents: Int,
        number: String?,
        description: String?,
        partNumber: String?
    ) {
        self.name = name
        self.quantity = quantity
        self.costCents = costCents
        self.number = number
        self.description = description
        self.partNumber = partNumber
    }

    enum CodingKeys: String, CodingKey {
        case name
        case quantity
        case costCents = "cost_cents"
        case number
        case description
        case partNumber = "part_number"
    }
}

public struct CreatePurchaseOrderRequest: Encodable, Sendable {
    public let vendorId: String
    public let notes: String?
    public let invoiceNumber: String?
    public let status: String?
    public let purchaseOrderId: String?
    public let orderId: String?
    public let lineItems: [CreatePurchaseOrderLineItemRequest]
    public let parts: [CreatePurchaseOrderPartRequest]
    public let fees: [CreatePurchaseOrderFeeRequest]
    public let tires: [CreatePurchaseOrderTireRequest]

    public init(
        vendorId: String,
        notes: String? = nil,
        invoiceNumber: String?,
        status: String?,
        purchaseOrderId: String? = nil,
        orderId: String? = nil,
        lineItems: [CreatePurchaseOrderLineItemRequest],
        parts: [CreatePurchaseOrderPartRequest] = [],
        fees: [CreatePurchaseOrderFeeRequest] = [],
        tires: [CreatePurchaseOrderTireRequest] = []
    ) {
        self.vendorId = vendorId
        self.notes = notes
        self.invoiceNumber = invoiceNumber
        self.status = status
        self.purchaseOrderId = purchaseOrderId
        self.orderId = orderId
        self.lineItems = lineItems
        self.parts = parts
        self.fees = fees
        self.tires = tires
    }

    enum CodingKeys: String, CodingKey {
        case vendorId = "vendor_id"
        case notes
        case invoiceNumber = "invoice_number"
        case status
        case purchaseOrderId = "purchase_order_id"
        case orderId = "order_id"
        case lineItems = "line_items"
        case parts
        case fees
        case tires
    }
}

private struct CreatePurchaseOrderUnitCostLineItemRequest: Encodable {
    let description: String
    let quantity: Int
    let unitCost: Decimal
    let name: String?
    let partNumber: String?
    let costCents: Int?

    enum CodingKeys: String, CodingKey {
        case description
        case quantity
        case unitCost = "unit_cost"
        case name
        case partNumber = "part_number"
        case costCents = "cost_cents"
    }
}

private struct CreatePurchaseOrderUnitCostRequest: Encodable {
    let vendorId: String
    let invoiceNumber: String?
    let status: String?
    let lineItems: [CreatePurchaseOrderUnitCostLineItemRequest]
    let parts: [CreatePurchaseOrderPartRequest]
    let fees: [CreatePurchaseOrderFeeRequest]
    let tires: [CreatePurchaseOrderTireRequest]

    enum CodingKeys: String, CodingKey {
        case vendorId = "vendor_id"
        case invoiceNumber = "invoice_number"
        case status
        case lineItems = "line_items"
        case parts
        case fees
        case tires
    }
}

private extension CreatePurchaseOrderRequest {
    func withStatus(_ status: String?) -> CreatePurchaseOrderRequest {
        CreatePurchaseOrderRequest(
            vendorId: vendorId,
            notes: notes,
            invoiceNumber: invoiceNumber,
            status: status,
            purchaseOrderId: purchaseOrderId,
            orderId: orderId,
            lineItems: lineItems,
            parts: parts,
            fees: fees,
            tires: tires
        )
    }
}

public struct CreatedResourceResponse: Decodable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct CreatePurchaseOrderResponse: Decodable, Sendable {
    public let id: String
    public let number: String?
    public let vendorId: String?
    public let status: String?

    public init(id: String, number: String? = nil, vendorId: String?, status: String?) {
        self.id = id
        self.number = number
        self.vendorId = vendorId
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let root = try JSONValue(from: decoder)

        // If server explicitly returns success=false, treat as invalid success payload.
        if let success = Self.firstBool(keys: ["success"], in: root), success == false {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Create PO payload indicates failure.")
            )
        }

        let resolvedId = Self.firstString(
            keys: [
                "id",
                "purchase_order_id",
                "purchaseOrderId",
                "po_id",
                "poId"
            ],
            in: root
        )
        let resolvedNumber = Self.firstString(
            keys: [
                "number",
                "po_number",
                "poNumber",
                "external_number",
                "externalNumber"
            ],
            in: root
        )
        let resolvedVendorId = Self.firstString(keys: ["vendor_id", "vendorId"], in: root)
        let resolvedStatus = Self.firstString(keys: ["status"], in: root)

        // Some tenants return only success/message for writes; avoid false decode failures on HTTP 2xx.
        self.id = resolvedId ?? resolvedNumber ?? "accepted"
        self.number = resolvedNumber
        self.vendorId = resolvedVendorId
        self.status = resolvedStatus
    }

    private static func firstString(keys: [String], in value: JSONValue) -> String? {
        let lookup = Set(keys.map { $0.lowercased() })
        return firstString(matching: lookup, in: value)
    }

    private static func firstString(matching keys: Set<String>, in value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            for (rawKey, candidate) in object {
                if keys.contains(rawKey.lowercased()),
                   let scalar = scalarString(from: candidate),
                   !scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return scalar
                }
            }

            // Prefer common envelope keys before recursive fallback scan.
            let envelopeKeys = ["data", "result", "purchase_order", "purchaseOrder", "response"]
            for key in envelopeKeys {
                if let nested = object[key],
                   let found = firstString(matching: keys, in: nested) {
                    return found
                }
            }

            for nested in object.values {
                if let found = firstString(matching: keys, in: nested) {
                    return found
                }
            }

            return nil

        case .array(let values):
            for nested in values {
                if let found = firstString(matching: keys, in: nested) {
                    return found
                }
            }
            return nil

        default:
            return nil
        }
    }

    private static func firstBool(keys: [String], in value: JSONValue) -> Bool? {
        let lookup = Set(keys.map { $0.lowercased() })
        return firstBool(matching: lookup, in: value)
    }

    private static func firstBool(matching keys: Set<String>, in value: JSONValue) -> Bool? {
        switch value {
        case .object(let object):
            for (rawKey, candidate) in object {
                if keys.contains(rawKey.lowercased()),
                   let scalar = scalarBool(from: candidate) {
                    return scalar
                }
            }

            for nested in object.values {
                if let found = firstBool(matching: keys, in: nested) {
                    return found
                }
            }

            return nil

        case .array(let values):
            for nested in values {
                if let found = firstBool(matching: keys, in: nested) {
                    return found
                }
            }
            return nil

        default:
            return nil
        }
    }

    private static func scalarString(from value: JSONValue) -> String? {
        switch value {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    private static func scalarBool(from value: JSONValue) -> Bool? {
        switch value {
        case .bool(let value):
            return value
        case .string(let value):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "true" { return true }
            if normalized == "false" { return false }
            return nil
        case .int(let value):
            return value != 0
        default:
            return nil
        }
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
    }
}

public struct PurchaseOrderResponse: Decodable, Identifiable, Sendable {
    public enum LineItemKind: String, Hashable, Sendable {
        case part
        case fee
        case tire
    }

    public struct LineItem: Hashable, Sendable {
        public let id: String?
        public let sku: String?
        public let name: String
        public let quantity: Int
        public let quantityReceived: Int?
        public let costCents: Int
        public let partNumber: String?
        public let kind: LineItemKind

        public init(
            id: String? = nil,
            sku: String? = nil,
            name: String,
            quantity: Int,
            quantityReceived: Int? = nil,
            costCents: Int,
            partNumber: String?,
            kind: LineItemKind
        ) {
            self.id = id
            self.sku = sku
            self.name = name
            self.quantity = quantity
            self.quantityReceived = quantityReceived
            self.costCents = costCents
            self.partNumber = partNumber
            self.kind = kind
        }
    }

    public let id: String
    public let vendorId: String?
    public let vendorName: String?
    public let number: String?
    public let orderId: String?
    public let status: String
    public let parts: [LineItem]
    public let fees: [LineItem]
    public let tires: [LineItem]

    public var isDraft: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "draft"
    }

    public var allLineItems: [LineItem] {
        parts + fees + tires
    }

    public init(
        id: String,
        vendorId: String?,
        vendorName: String? = nil,
        number: String? = nil,
        orderId: String? = nil,
        status: String,
        parts: [LineItem] = [],
        fees: [LineItem] = [],
        tires: [LineItem] = []
    ) {
        self.id = id
        self.vendorId = vendorId
        self.vendorName = vendorName
        self.number = number
        self.orderId = orderId
        self.status = status
        self.parts = parts
        self.fees = fees
        self.tires = tires
    }

    public init(from decoder: Decoder) throws {
        let root = try JSONValue(from: decoder)

        guard let resolvedID = Self.firstString(
            keys: [
                "id",
                "purchase_order_id",
                "purchaseOrderId",
                "po_id",
                "poId",
                "number",
                "po_number",
                "poNumber"
            ],
            in: root
        ) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Missing purchase order identifier.")
            )
        }

        let resolvedVendorID = Self.firstString(keys: ["vendor_id", "vendorId"], in: root)
        let resolvedVendorName = Self.firstString(keys: ["vendor_name", "vendorName", "name"], in: root)
        let resolvedNumber = Self.firstString(keys: ["number", "external_number", "externalNumber"], in: root)
        let resolvedOrderID = Self.firstString(keys: ["order_id", "orderId"], in: root)
        let resolvedStatus = Self.firstString(keys: ["status", "state"], in: root) ?? "unknown"
        let resolvedParts = Self.parseLineItems(from: root, key: "parts", kind: .part)
        let resolvedFees = Self.parseLineItems(from: root, key: "fees", kind: .fee)
        let resolvedTires = Self.parseLineItems(from: root, key: "tires", kind: .tire)

        self.id = resolvedID
        self.vendorId = resolvedVendorID
        self.vendorName = resolvedVendorName
        self.number = resolvedNumber
        self.orderId = resolvedOrderID
        self.status = resolvedStatus
        self.parts = resolvedParts
        self.fees = resolvedFees
        self.tires = resolvedTires
    }

    private static func firstString(keys: [String], in value: JSONValue) -> String? {
        let lookup = Set(keys.map { $0.lowercased() })
        return firstString(matching: lookup, in: value)
    }

    private static func firstString(matching keys: Set<String>, in value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            for (rawKey, candidate) in object {
                if keys.contains(rawKey.lowercased()),
                   let scalar = scalarString(from: candidate),
                   !scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return scalar
                }
            }

            let envelopeKeys = ["data", "result", "purchase_order", "purchaseOrder", "response"]
            for key in envelopeKeys {
                if let nested = object[key],
                   let found = firstString(matching: keys, in: nested) {
                    return found
                }
            }

            for nested in object.values {
                if let found = firstString(matching: keys, in: nested) {
                    return found
                }
            }
            return nil

        case .array(let values):
            for nested in values {
                if let found = firstString(matching: keys, in: nested) {
                    return found
                }
            }
            return nil

        default:
            return nil
        }
    }

    private static func scalarString(from value: JSONValue) -> String? {
        switch value {
        case .string(let raw):
            return raw
        case .int(let raw):
            return String(raw)
        case .double(let raw):
            return String(raw)
        case .bool(let raw):
            return raw ? "true" : "false"
        case .null, .object, .array:
            return nil
        }
    }

    private static func parseLineItems(from value: JSONValue, key: String, kind: LineItemKind) -> [LineItem] {
        guard let collection = findNestedValue(forKey: key, in: value) else {
            return []
        }

        guard case .array(let values) = collection else {
            return []
        }

        var parsed: [LineItem] = []
        for candidate in values {
            guard case .object(let itemObject) = candidate else { continue }

            let name = scalarString(from: itemObject["name"] ?? itemObject["description"] ?? .null)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty { continue }

            let quantity = scalarInt(from: itemObject["quantity"] ?? .int(1)) ?? 1
            let lineItemID = scalarString(
                from: itemObject["line_item_id"]
                    ?? itemObject["lineItemId"]
                    ?? itemObject["id"]
                    ?? itemObject["part_id"]
                    ?? itemObject["partId"]
                    ?? .null
            )
            let sku = scalarString(
                from: itemObject["sku"]
                    ?? itemObject["part_sku"]
                    ?? itemObject["partSku"]
                    ?? itemObject["item_sku"]
                    ?? itemObject["itemSku"]
                    ?? .null
            )
            let quantityReceived = scalarInt(
                from: itemObject["quantity_received"]
                    ?? itemObject["quantityReceived"]
                    ?? itemObject["received_quantity"]
                    ?? itemObject["receivedQuantity"]
                    ?? itemObject["received_qty"]
                    ?? itemObject["receivedQty"]
                    ?? itemObject["qty_received"]
                    ?? itemObject["qtyReceived"]
                    ?? .null
            )
            let costCents = scalarInt(
                from: itemObject["cost_cents"]
                    ?? itemObject["costCents"]
                    ?? itemObject["unit_cost_cents"]
                    ?? itemObject["unitCostCents"]
                    ?? itemObject["amount_cents"]
                    ?? itemObject["amountCents"]
                    ?? .int(0)
            ) ?? 0
            let partNumber = scalarString(from: itemObject["part_number"] ?? itemObject["partNumber"] ?? itemObject["number"] ?? .null)

            parsed.append(
                LineItem(
                    id: lineItemID,
                    sku: sku,
                    name: name,
                    quantity: max(1, quantity),
                    quantityReceived: quantityReceived.map { max(0, $0) },
                    costCents: max(0, costCents),
                    partNumber: partNumber,
                    kind: kind
                )
            )
        }

        return parsed
    }

    private static func findNestedValue(forKey targetKey: String, in value: JSONValue) -> JSONValue? {
        switch value {
        case .object(let object):
            for (rawKey, nested) in object where rawKey.lowercased() == targetKey.lowercased() {
                return nested
            }

            for nested in object.values {
                if let found = findNestedValue(forKey: targetKey, in: nested) {
                    return found
                }
            }
            return nil

        case .array(let values):
            for nested in values {
                if let found = findNestedValue(forKey: targetKey, in: nested) {
                    return found
                }
            }
            return nil

        default:
            return nil
        }
    }

    private static func scalarInt(from value: JSONValue) -> Int? {
        switch value {
        case .int(let raw):
            return raw
        case .double(let raw):
            return Int(raw.rounded())
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                return intValue
            }
            if let decimal = Decimal(string: trimmed) {
                return NSDecimalNumber(decimal: decimal).intValue
            }
            return nil
        default:
            return nil
        }
    }
}

private struct TicketPartLineItemCreateRequest: Encodable {
    let sku: String?
    let partNumber: String?
    let description: String
    let quantity: Decimal
    let unitPrice: Decimal?

    enum CodingKeys: String, CodingKey {
        case sku
        case partNumber = "part_number"
        case description
        case name
        case quantity
        case unitPrice = "unit_price"
        case unitCost = "unit_cost"
        case unitCostCents = "unit_cost_cents"
        case cost = "cost"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sku, forKey: .sku)
        try container.encodeIfPresent(partNumber, forKey: .partNumber)
        try container.encode(description, forKey: .description)
        try container.encode(description, forKey: .name)
        try container.encode(quantity, forKey: .quantity)

        if let unitPrice {
            try container.encode(unitPrice, forKey: .unitPrice)
            try container.encode(unitPrice, forKey: .unitCost)
            let cents = NSDecimalNumber(decimal: unitPrice * Decimal(100)).intValue
            try container.encode(cents, forKey: .unitCostCents)
            try container.encode(unitPrice, forKey: .cost)
        }
    }
}

private struct TicketPartLineItemCreateResponse: Decodable {
    let lineItem: TicketLineItem

    init(from decoder: Decoder) throws {
        let root = try JSONValue(from: decoder)
        guard let lineItemObject = Self.resolveLineItemObject(from: root),
              let lineItem = Self.parseLineItem(from: lineItemObject) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected ticket line item response.")
            )
        }
        self.lineItem = lineItem
    }

    private static func resolveLineItemObject(from value: JSONValue) -> [String: JSONValue]? {
        switch value {
        case .object(let object):
            if looksLikeLineItem(object) {
                return object
            }

            for key in ["data", "result", "item", "line_item", "lineItem", "part"] {
                if let nested = objectValue(for: key, in: object) {
                    if looksLikeLineItem(nested) {
                        return nested
                    }
                    if let firstFromNested = firstLineItemObject(in: nested) {
                        return firstFromNested
                    }
                }
            }

            if let firstNested = firstLineItemObject(in: object) {
                return firstNested
            }
            return nil

        case .array(let values):
            for entry in values {
                if let resolved = resolveLineItemObject(from: entry) {
                    return resolved
                }
            }
            return nil

        default:
            return nil
        }
    }

    private static func firstLineItemObject(in object: [String: JSONValue]) -> [String: JSONValue]? {
        for key in ["line_items", "lineItems", "items", "parts"] {
            guard let collection = arrayValue(for: key, in: object) else { continue }
            for entry in collection {
                if case .object(let nested) = entry, looksLikeLineItem(nested) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func looksLikeLineItem(_ object: [String: JSONValue]) -> Bool {
        let keys = object.keys.map { $0.lowercased() }
        return keys.contains("id")
            && (keys.contains("description") || keys.contains("name"))
            && (keys.contains("quantity") || keys.contains("qty"))
    }

    private static func parseLineItem(from object: [String: JSONValue]) -> TicketLineItem? {
        guard let id = firstNonEmpty([
            string(in: object, keys: ["id", "public_id", "publicId"])
        ]) else {
            return nil
        }

        let quantity = firstDecimal([
            scalar(in: object, keys: ["quantity", "qty"]),
            .int(1)
        ]) ?? 1

        let unitPrice = firstDecimal([
            scalar(in: object, keys: ["unit_price", "unitPrice", "price", "cost", "unit_cost", "unitCost"])
        ])
        let extendedPrice = firstDecimal([
            scalar(in: object, keys: ["extended_price", "extendedPrice", "line_total", "lineTotal", "amount"])
        ])

        return TicketLineItem(
            id: id,
            kind: firstNonEmpty([
                string(in: object, keys: ["kind", "type", "category"]),
                "part"
            ]),
            sku: string(in: object, keys: ["sku"]),
            partNumber: firstNonEmpty([
                string(in: object, keys: ["part_number", "partNumber", "number"])
            ]),
            description: firstNonEmpty([
                string(in: object, keys: ["description", "name"])
            ]) ?? "Line Item",
            quantity: quantity,
            unitPrice: unitPrice,
            extendedPrice: extendedPrice ?? unitPrice.map { $0 * quantity },
            vendorId: string(in: object, keys: ["vendor_id", "vendorId"])
        )
    }

    private static func objectValue(for key: String, in object: [String: JSONValue]) -> [String: JSONValue]? {
        guard let value = object.first(where: { $0.key.lowercased() == key.lowercased() })?.value else {
            return nil
        }
        if case .object(let nested) = value {
            return nested
        }
        return nil
    }

    private static func arrayValue(for key: String, in object: [String: JSONValue]) -> [JSONValue]? {
        guard let value = object.first(where: { $0.key.lowercased() == key.lowercased() })?.value else {
            return nil
        }
        if case .array(let nested) = value {
            return nested
        }
        return nil
    }

    private static func scalar(in object: [String: JSONValue], keys: [String]) -> JSONValue? {
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            return value
        }
        return nil
    }

    private static func string(in object: [String: JSONValue], keys: [String]) -> String? {
        guard let value = scalar(in: object, keys: keys) else { return nil }
        switch value {
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func firstDecimal(_ values: [JSONValue?]) -> Decimal? {
        for value in values {
            guard let value else { continue }
            switch value {
            case .int(let raw):
                return Decimal(raw)
            case .double(let raw):
                guard raw.isFinite else { continue }
                return Decimal(raw)
            case .string(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let decimal = Decimal(string: trimmed) {
                    return decimal
                }
            default:
                continue
            }
        }
        return nil
    }
}

private struct OrderDetailEnvelope: Decodable {
    let alternateOrderIDs: [String]
    let services: [ServiceSummary]

    init(from decoder: Decoder) throws {
        let rootValue = try JSONValue(from: decoder)
        guard case .object(let rootObject) = rootValue else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected order object.")
            )
        }

        let orderObject = Self.resolveOrderObject(from: rootObject)

        alternateOrderIDs = Self.collectOrderIDs(orderObject: orderObject, rootObject: rootObject)
        services = Self.extractServices(orderObject: orderObject, rootObject: rootObject)
    }

    private static func resolveOrderObject(from root: [String: JSONValue]) -> [String: JSONValue] {
        if let nested = object(in: root, keys: ["order", "ticket"]) {
            return nested
        }

        if let first = firstObject(in: root, keys: ["data", "result", "results"]) {
            return first
        }

        return root
    }

    private static func collectOrderIDs(
        orderObject: [String: JSONValue],
        rootObject: [String: JSONValue]
    ) -> [String] {
        let candidates = [
            string(in: orderObject, keys: ["id", "public_id", "publicId"]),
            string(in: rootObject, keys: ["id", "public_id", "publicId"]),
            string(in: orderObject, keys: ["order_id", "orderId"]),
            string(in: rootObject, keys: ["order_id", "orderId"])
        ]

        var unique: [String] = []
        var seen: Set<String> = []

        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let dedupeKey = trimmed.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }
            unique.append(trimmed)
        }

        return unique
    }

    private static func extractServices(
        orderObject: [String: JSONValue],
        rootObject: [String: JSONValue]
    ) -> [ServiceSummary] {
        var parsed: [ServiceSummary] = []
        var seen: Set<String> = []

        for serviceObject in serviceObjects(in: .object(orderObject)) + serviceObjects(in: .object(rootObject)) {
            guard let serviceID = firstNonEmpty([
                string(in: serviceObject, keys: ["id", "public_id", "publicId"]),
                string(in: serviceObject, keys: ["service_id", "serviceId", "order_service_id", "orderServiceId"])
            ]) else {
                continue
            }

            let trimmedID = serviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else { continue }

            let dedupeKey = trimmedID.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }

            let rawName = firstNonEmpty([
                string(in: serviceObject, keys: ["name", "display_name", "displayName"]),
                string(in: serviceObject, keys: ["description", "generated_name", "generatedName"])
            ])
            let trimmedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)

            parsed.append(
                ServiceSummary(
                    id: trimmedID,
                    name: (trimmedName?.isEmpty == false) ? trimmedName : nil
                )
            )
        }

        return parsed
    }

    private static func serviceObjects(in value: JSONValue) -> [[String: JSONValue]] {
        switch value {
        case .object(let object):
            var parsed: [[String: JSONValue]] = []
            let containerKeys = Set(["services", "service", "service_list", "serviceList"].map { $0.lowercased() })
            let traversalKeys = Set(["data", "result", "results", "order", "ticket"].map { $0.lowercased() })

            for (rawKey, nested) in object {
                let key = rawKey.lowercased()
                if containerKeys.contains(key) {
                    parsed.append(contentsOf: objects(from: nested))
                }
                if traversalKeys.contains(key) {
                    parsed.append(contentsOf: serviceObjects(in: nested))
                }
            }

            return parsed

        case .array(let values):
            var parsed: [[String: JSONValue]] = []
            for nested in values {
                parsed.append(contentsOf: serviceObjects(in: nested))
            }
            return parsed

        default:
            return []
        }
    }

    private static func objects(from value: JSONValue) -> [[String: JSONValue]] {
        switch value {
        case .object(let object):
            return [object]
        case .array(let values):
            return values.compactMap { value in
                if case .object(let object) = value {
                    return object
                }
                return nil
            }
        default:
            return []
        }
    }

    private static func object(in object: [String: JSONValue], keys: [String]) -> [String: JSONValue]? {
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            if case .object(let nested) = value {
                return nested
            }
        }
        return nil
    }

    private static func firstObject(in object: [String: JSONValue], keys: [String]) -> [String: JSONValue]? {
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            switch value {
            case .object(let nested):
                return nested
            case .array(let values):
                for entry in values {
                    if case .object(let nested) = entry {
                        return nested
                    }
                }
            default:
                break
            }
        }
        return nil
    }

    private static func string(in object: [String: JSONValue], keys: [String]) -> String? {
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            guard let scalar = scalarString(from: value) else { continue }
            let trimmed = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func scalarString(from value: JSONValue) -> String? {
        switch value {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }
}

private struct TicketEnvelope: Decodable {
    let id: String
    let number: String?
    let displayNumber: String?
    let status: String?
    let customerName: String?
    let vehicleSummary: String?
    let updatedAt: Date?
    let lineItems: [TicketLineItem]

    init(from decoder: Decoder) throws {
        let rootValue = try JSONValue(from: decoder)
        guard case .object(let rootObject) = rootValue else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected ticket object.")
            )
        }

        let ticketObject = Self.resolveTicketObject(from: rootObject)

        guard let resolvedID = Self.firstNonEmpty([
            Self.string(in: ticketObject, keys: ["id", "public_id", "publicId"]),
            Self.string(in: rootObject, keys: ["id", "public_id", "publicId"]),
            Self.string(in: ticketObject, keys: ["order_id", "orderId"]),
            Self.string(in: rootObject, keys: ["order_id", "orderId"])
        ]) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Missing ticket identifier.")
            )
        }

        let customerContainer = Self.object(in: ticketObject, keys: ["customer", "customer_info", "customerInfo"])
        let vehicleContainer = Self.object(in: ticketObject, keys: ["vehicle", "vehicle_info", "vehicleInfo"])

        id = resolvedID
        number = Self.firstNonEmpty([
            Self.string(in: ticketObject, keys: ["number", "ticket_number", "ticketNumber", "external_number", "externalNumber"]),
            Self.string(in: rootObject, keys: ["number", "ticket_number", "ticketNumber", "external_number", "externalNumber"])
        ])
        displayNumber = Self.firstNonEmpty([
            Self.string(in: ticketObject, keys: ["display_number", "displayNumber"]),
            Self.string(in: rootObject, keys: ["display_number", "displayNumber"]),
            number
        ])
        status = Self.firstNonEmpty([
            Self.string(in: ticketObject, keys: ["status", "state"]),
            Self.string(in: rootObject, keys: ["status", "state"])
        ])
        customerName = Self.firstNonEmpty([
            Self.string(in: ticketObject, keys: ["generated_customer_name", "generatedCustomerName", "customer_name", "customerName"]),
            Self.string(in: customerContainer, keys: ["name"]),
            Self.string(in: rootObject, keys: ["generated_customer_name", "generatedCustomerName", "customer_name", "customerName"])
        ])
        vehicleSummary = Self.firstNonEmpty([
            Self.string(in: ticketObject, keys: ["vehicle_summary", "vehicleSummary"]),
            Self.string(in: vehicleContainer, keys: ["name", "display_name", "displayName", "vin"]),
            Self.string(in: rootObject, keys: ["vehicle_summary", "vehicleSummary"])
        ])
        updatedAt = Self.firstDate([
            Self.string(in: ticketObject, keys: ["updated_at", "updatedAt", "modified_at", "modifiedAt"]),
            Self.string(in: rootObject, keys: ["updated_at", "updatedAt", "modified_at", "modifiedAt"])
        ])
        lineItems = Self.parseLineItems(from: ticketObject, ticketID: resolvedID)
    }

    func ticketModel(includeLineItems: Bool) -> TicketModel {
        TicketModel(
            id: id,
            number: number,
            displayNumber: displayNumber ?? number,
            status: status,
            customerName: customerName,
            vehicleSummary: vehicleSummary,
            updatedAt: updatedAt,
            lineItems: includeLineItems ? lineItems : []
        )
    }

    private static func resolveTicketObject(from root: [String: JSONValue]) -> [String: JSONValue] {
        if containsTicketIdentityFields(root) {
            return root
        }

        if let nested = object(in: root, keys: ["order", "ticket", "order_summary", "orderSummary"]) {
            return nested
        }

        if let first = firstObject(in: root, keys: ["data", "result", "results"]) {
            return first
        }

        return root
    }

    private static func parseLineItems(from object: [String: JSONValue], ticketID: String) -> [TicketLineItem] {
        var parsed: [TicketLineItem] = []
        var index = 0

        func appendLineItems(from values: [JSONValue], kindHint: String?) {
            for value in values {
                if let lineItem = parseLineItem(value, index: index, ticketID: ticketID, kindHint: kindHint) {
                    parsed.append(lineItem)
                    index += 1
                }
            }
        }

        appendLineItems(from: objectArray(in: object, keys: ["line_items", "lineItems", "items"]), kindHint: nil)
        appendLineItems(from: objectArray(in: object, keys: ["parts"]), kindHint: "part")
        appendLineItems(from: objectArray(in: object, keys: ["tires"]), kindHint: "tire")
        appendLineItems(from: objectArray(in: object, keys: ["fees"]), kindHint: "fee")
        appendLineItems(from: objectArray(in: object, keys: ["labor", "labors"]), kindHint: "labor")

        if parsed.isEmpty {
            // Some tenants nest ticket line items under each service object.
            for service in objectArray(in: object, keys: ["services", "service"]) {
                guard case .object(let serviceObject) = service else { continue }
                appendLineItems(from: objectArray(in: serviceObject, keys: ["line_items", "lineItems", "items"]), kindHint: nil)
                appendLineItems(from: objectArray(in: serviceObject, keys: ["parts"]), kindHint: "part")
                appendLineItems(from: objectArray(in: serviceObject, keys: ["tires"]), kindHint: "tire")
                appendLineItems(from: objectArray(in: serviceObject, keys: ["fees"]), kindHint: "fee")
                appendLineItems(from: objectArray(in: serviceObject, keys: ["labor", "labors"]), kindHint: "labor")
            }
        }

        return parsed
    }

    private static func parseLineItem(
        _ value: JSONValue,
        index: Int,
        ticketID: String,
        kindHint: String?
    ) -> TicketLineItem? {
        guard case .object(let object) = value else { return nil }

        let id = firstNonEmpty([
            string(in: object, keys: ["id", "public_id", "publicId"]),
            "\(ticketID)_\(index + 1)"
        ]) ?? "\(ticketID)_\(index + 1)"

        let quantity = firstDecimal([
            scalar(in: object, keys: ["quantity", "qty"]),
            .int(0)
        ]) ?? 0

        return TicketLineItem(
            id: id,
            kind: firstNonEmpty([
                string(in: object, keys: ["kind", "type", "category"]),
                kindHint
            ]),
            sku: string(in: object, keys: ["sku"]),
            partNumber: firstNonEmpty([
                string(in: object, keys: ["part_number", "partNumber", "number"])
            ]),
            description: firstNonEmpty([
                string(in: object, keys: ["description", "name"])
            ]) ?? "Line Item",
            quantity: quantity,
            unitPrice: firstDecimal([
                scalar(in: object, keys: ["unit_price", "unitPrice", "price", "cost"]),
                scalar(in: object, keys: ["unit_cost", "unitCost"])
            ]),
            extendedPrice: firstDecimal([
                scalar(in: object, keys: ["extended_price", "extendedPrice", "line_total", "lineTotal", "amount"])
            ]),
            vendorId: string(in: object, keys: ["vendor_id", "vendorId"])
        )
    }

    private static func containsTicketIdentityFields(_ object: [String: JSONValue]) -> Bool {
        let lookup = Set(["id", "orderid", "order_id", "number", "ticketnumber", "ticket_number"])
        return object.keys.contains { lookup.contains($0.lowercased()) }
    }

    private static func object(in object: [String: JSONValue]?, keys: [String]) -> [String: JSONValue]? {
        guard let object else { return nil }
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            if case .object(let nested) = value {
                return nested
            }
        }
        return nil
    }

    private static func firstObject(in object: [String: JSONValue], keys: [String]) -> [String: JSONValue]? {
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            switch value {
            case .object(let nested):
                return nested
            case .array(let values):
                for entry in values {
                    if case .object(let nested) = entry {
                        return nested
                    }
                }
            default:
                break
            }
        }
        return nil
    }

    private static func objectArray(in object: [String: JSONValue], keys: [String]) -> [JSONValue] {
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            if case .array(let values) = value {
                return values
            }
        }
        return []
    }

    private static func scalar(in object: [String: JSONValue], keys: [String]) -> JSONValue? {
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            return value
        }
        return nil
    }

    private static func string(in object: [String: JSONValue]?, keys: [String]) -> String? {
        guard let object else { return nil }
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            if let scalar = scalarString(from: value) {
                let trimmed = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func firstDate(_ candidates: [String?]) -> Date? {
        for candidate in candidates {
            guard let candidate else { continue }
            if let date = iso8601Formatter.date(from: candidate) ?? iso8601FractionalFormatter.date(from: candidate) {
                return date
            }
        }
        return nil
    }

    private static func firstDecimal(_ candidates: [JSONValue?]) -> Decimal? {
        for candidate in candidates {
            guard let candidate else { continue }
            switch candidate {
            case .int(let value):
                return Decimal(value)
            case .double(let value):
                guard value.isFinite else { continue }
                return Decimal(value)
            case .string(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let decimal = Decimal(string: trimmed) {
                    return decimal
                }
            default:
                continue
            }
        }
        return nil
    }

    private static func scalarString(from value: JSONValue) -> String? {
        switch value {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public struct OrderSummary: Decodable, Identifiable, Sendable {
    public let id: String
    public let number: String?
    public let orderName: String?
    public let customerName: String?

    public var displayTitle: String {
        let trimmedNumber = number?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrderName = orderName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedNumber, !trimmedNumber.isEmpty, let trimmedOrderName, !trimmedOrderName.isEmpty {
            return "Order #\(trimmedNumber) • \(trimmedOrderName)"
        }

        if let trimmedNumber, !trimmedNumber.isEmpty {
            return "Order #\(trimmedNumber)"
        }

        if let trimmedOrderName, !trimmedOrderName.isEmpty {
            return trimmedOrderName
        }

        return "Order \(id)"
    }

    public init(id: String, number: String?, orderName: String? = nil, customerName: String? = nil) {
        self.id = id
        self.number = number
        self.orderName = orderName
        self.customerName = customerName
    }

    public init(from decoder: Decoder) throws {
        let rootValue = try JSONValue(from: decoder)
        guard case .object(let rootObject) = rootValue else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected order object.")
            )
        }

        let orderObject = Self.resolveOrderObject(from: rootObject)

        guard let resolvedID = Self.firstNonEmpty([
            Self.string(in: orderObject, keys: ["id", "public_id", "publicId"]),
            Self.string(in: rootObject, keys: ["id", "public_id", "publicId"]),
            Self.string(in: orderObject, keys: ["order_id", "orderId"]),
            Self.string(in: rootObject, keys: ["order_id", "orderId"])
        ]) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Missing order identifier.")
            )
        }

        let orderContainer = Self.object(in: orderObject, keys: ["order", "order_summary", "orderSummary"])
        let customerContainer = Self.object(in: rootObject, keys: ["customer", "customer_info", "customerInfo"])

        self.id = resolvedID
        self.number = Self.firstNonEmpty([
            Self.string(in: orderObject, keys: ["number", "external_number", "externalNumber"]),
            Self.string(in: orderContainer, keys: ["number", "external_number", "externalNumber"]),
            Self.string(in: rootObject, keys: ["number", "external_number", "externalNumber"])
        ])
        self.orderName = Self.firstNonEmpty([
            Self.string(in: orderObject, keys: ["coalesced_name", "coalescedName"]),
            Self.string(in: orderObject, keys: ["generated_name", "generatedName"]),
            Self.string(in: orderObject, keys: ["name"]),
            Self.string(in: orderContainer, keys: ["coalesced_name", "coalescedName", "generated_name", "generatedName", "name"]),
            Self.string(in: rootObject, keys: ["coalesced_name", "coalescedName", "generated_name", "generatedName", "name"])
        ])
        self.customerName = Self.firstNonEmpty([
            Self.string(in: orderObject, keys: ["generated_customer_name", "generatedCustomerName", "customer_name", "customerName"]),
            Self.string(in: rootObject, keys: ["generated_customer_name", "generatedCustomerName", "customer_name", "customerName"]),
            Self.string(in: customerContainer, keys: ["name"])
        ])
    }

    private static func resolveOrderObject(from root: [String: JSONValue]) -> [String: JSONValue] {
        if containsOrderIdentityFields(root) {
            return root
        }

        if let nestedOrder = object(in: root, keys: ["order", "order_summary", "orderSummary"]) {
            return nestedOrder
        }

        if let dataEntry = firstObject(in: root, keys: ["data", "result", "results"]) {
            return dataEntry
        }

        return root
    }

    private static func containsOrderIdentityFields(_ object: [String: JSONValue]) -> Bool {
        let lookup = Set(["id", "number", "coalescedname", "generatedname", "orderid", "order_id"])
        for key in object.keys where lookup.contains(key.lowercased()) {
            return true
        }
        return false
    }

    private static func object(in object: [String: JSONValue]?, keys: [String]) -> [String: JSONValue]? {
        guard let object else { return nil }
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            if case .object(let nested) = value {
                return nested
            }
        }
        return nil
    }

    private static func firstObject(in object: [String: JSONValue], keys: [String]) -> [String: JSONValue]? {
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            switch value {
            case .object(let nested):
                return nested
            case .array(let values):
                for entry in values {
                    if case .object(let nested) = entry {
                        return nested
                    }
                }
            default:
                break
            }
        }
        return nil
    }

    private static func string(in object: [String: JSONValue]?, keys: [String]) -> String? {
        guard let object else { return nil }
        let lookup = Set(keys.map { $0.lowercased() })

        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            if let scalar = scalarString(from: value) {
                let trimmed = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func scalarString(from value: JSONValue) -> String? {
        switch value {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }
}

public struct ServiceSummary: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String?

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object(let object) = value else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected service object.")
            )
        }

        guard let resolvedID = Self.firstNonEmpty([
            Self.string(in: object, keys: ["id", "public_id", "publicId"]),
            Self.string(in: object, keys: ["service_id", "serviceId", "order_service_id", "orderServiceId"])
        ]) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Missing service identifier.")
            )
        }

        id = resolvedID
        name = Self.firstNonEmpty([
            Self.string(in: object, keys: ["name", "display_name", "displayName"]),
            Self.string(in: object, keys: ["description", "generated_name", "generatedName"])
        ])
    }

    private static func string(in object: [String: JSONValue], keys: [String]) -> String? {
        let lookup = Set(keys.map { $0.lowercased() })
        for (rawKey, value) in object where lookup.contains(rawKey.lowercased()) {
            guard let scalar = scalarString(from: value) else { continue }
            let trimmed = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func scalarString(from value: JSONValue) -> String? {
        switch value {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }
}
