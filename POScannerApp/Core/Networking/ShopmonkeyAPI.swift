//
//  ShopmonkeyAPI.swift
//  POScannerApp
//

import Foundation

protocol ShopmonkeyServicing {
    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse
    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse
    func createFee(orderId: String, serviceId: String, request: CreateFeeRequest) async throws -> CreatedResourceResponse
    func createTire(orderId: String, serviceId: String, request: CreateTireRequest) async throws -> CreatedResourceResponse
    func createPurchaseOrder(_ request: CreatePurchaseOrderRequest) async throws -> CreatePurchaseOrderResponse
    func getPurchaseOrders() async throws -> [PurchaseOrderResponse]
    func fetchOrders() async throws -> [OrderSummary]
    func fetchServices(orderId: String) async throws -> [ServiceSummary]
    func searchVendors(name: String) async throws -> [VendorSummary]
    func testConnection() async throws
}

extension ShopmonkeyServicing {
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
}

enum ProbeHTTPMethod: String {
    case get = "GET"
    case post = "POST"
}

struct EndpointProbeResult: Hashable, Identifiable {
    var id: String { endpoint + "|" + method.rawValue }
    let endpoint: String
    let method: ProbeHTTPMethod
    let statusCode: Int?
    let supported: Bool
    let hint: String
    let responsePreview: String?
}

struct ShopmonkeyEndpointProbeReport: Hashable {
    let generatedAt: Date
    let results: [EndpointProbeResult]

    var createPurchaseOrderLikelySupported: Bool {
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

private struct DataWrapper<T: Decodable>: Decodable {
    let data: [T]
}

private struct ResultsWrapper<T: Decodable>: Decodable {
    let results: [T]
}

/// Shopmonkey sandbox API wrapper.
struct ShopmonkeyAPI: ShopmonkeyServicing {
    #if DEBUG
    // sandbox only
    private let baseURL = URL(string: "https://sandbox-api.shopmonkey.cloud/v3")!
    #else
    #error("Production API not allowed in this build.")
    #endif

    /// Exposed for dependency wiring and tests (still sandbox-only).
    static var baseURL: URL {
        #if DEBUG
        return URL(string: "https://sandbox-api.shopmonkey.cloud/v3")!
        #else
        #error("Production API not allowed in this build.")
        #endif
    }

    private let client: APIClient
    private let keychain: KeychainService
    private let diagnosticsRecorder: NetworkDiagnosticsRecorder

    init(
        client: APIClient,
        keychain: KeychainService = KeychainService(),
        diagnosticsRecorder: NetworkDiagnosticsRecorder = .shared
    ) {
        self.client = client
        self.keychain = keychain
        self.diagnosticsRecorder = diagnosticsRecorder
    }

    // MARK: - Endpoints

    /// POST /vendor
    func createVendor(_ request: CreateVendorRequest) async throws -> CreateVendorResponse {
        let url = try makeURL(path: "/vendor")
        let body = try APIClient.encodeJSON(request)
        let response: CreateVendorResponse = try await client.perform(.post, url: url, body: body)
        try validate(response)
        return response
    }

    /// POST /order/{orderId}/service/{serviceId}/part
    func createPart(orderId: String, serviceId: String, request: CreatePartRequest) async throws -> CreatePartResponse {
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
    func createFee(orderId: String, serviceId: String, request: CreateFeeRequest) async throws -> CreatedResourceResponse {
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
    func createTire(orderId: String, serviceId: String, request: CreateTireRequest) async throws -> CreatedResourceResponse {
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
    func createPurchaseOrder(_ request: CreatePurchaseOrderRequest) async throws -> CreatePurchaseOrderResponse {
        // Try canonical singular route first. Only use plural if singular route itself is unavailable.
        do {
            return try await createPurchaseOrderOnRoute("/purchase_order", request: request)
        } catch let error as APIError {
            guard isRouteUnavailable(error) else {
                throw error
            }
        }

        // Tenant fallback: some deployments expose plural route only.
        return try await createPurchaseOrderOnRoute("/purchase_orders", request: request)
    }

    /// GET /purchase_order
    func getPurchaseOrders() async throws -> [PurchaseOrderResponse] {
        let url = try makeURL(path: "/purchase_order")
        let decoded: ListOrWrapped<PurchaseOrderResponse> = try await client.perform(.get, url: url)
        let values = decoded.values
        for po in values {
            try validate(po)
        }
        return values
    }

    /// GET /order
    func fetchOrders() async throws -> [OrderSummary] {
        let url = try makeURL(path: "/order")
        let decoded: ListOrWrapped<OrderSummary> = try await client.perform(.get, url: url)
        return decoded.values
    }

    /// GET /order/{orderId}/service
    func fetchServices(orderId: String) async throws -> [ServiceSummary] {
        let safeOrderId = orderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeOrderId.isEmpty else {
            throw APIError.invalidURL
        }

        let url = try makeURL(path: "/order/\(safeOrderId)/service")
        let decoded: ListOrWrapped<ServiceSummary> = try await client.perform(.get, url: url)
        return decoded.values
    }

    /// GET /vendor?search={name}
    func searchVendors(name: String) async throws -> [VendorSummary] {
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
    func testConnection() async throws {
        let url = baseURL.appendingPathComponent("order")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let token: String
        do {
            token = try keychain.retrieveToken()
        } catch KeychainService.KeychainServiceError.itemNotFound {
            throw APIError.missingToken
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw APIError.missingToken
        }

        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")

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

        #if DEBUG
        print("Test Connection Status Code: \(httpResponse.statusCode)")
        #endif

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
    func runEndpointProbe() async throws -> ShopmonkeyEndpointProbeReport {
        let probes: [(ProbeHTTPMethod, String, [String: String]?)] = [
            (.get, "/order", nil),
            (.get, "/purchase_order", nil),
            (.post, "/purchase_order/search", ["query": ""]),
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

    // MARK: - URL building

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
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
        VendorMatcher.rankVendors(
            vendors,
            query: query,
            minimumScore: VendorMatcher.minimumSuggestionScore
        ).map(\.vendor)
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

        let token: String
        do {
            token = try keychain.retrieveToken()
        } catch KeychainService.KeychainServiceError.itemNotFound {
            throw APIError.missingToken
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw APIError.missingToken
        }
        request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")

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

        while index < statusesToTry.count {
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

                        let isLastBodyMode = bodyMode == bodyModes.last

                        // Try another body mode first; only evaluate status fallbacks when modes are exhausted.
                        if !isLastBodyMode {
                            continue
                        }

                        // Only cycle through additional statuses when server explicitly flags status as invalid.
                        if await isStatusValidationFailure(for: path) {
                            if !didLoadFailureDerivedStatuses {
                                didLoadFailureDerivedStatuses = true
                                let additionalStatuses = await additionalStatusCandidates(for: path)
                                appendStatusCandidates(
                                    additionalStatuses,
                                    to: &statusesToTry,
                                    queuedKeys: &queuedKeys
                                )
                            }
                            continue
                        }
                        throw secondError
                    }
                }
            }
        }

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
        let defaults = [
            // Matches observed Shopmonkey PO status dropdown in sandbox tenant.
            "draft",
            "ordered",
            "received",
            "fulfilled",
            "cancelled",
            "canceled",
            "open",
            "submitted",
            "closed",
            "created",
            "complete",
            "pending"
        ]

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

        // Let server default if status is optional.
        append(nil)
        append(preferredPurchaseOrderStatus())
        append(initial)

        for status in additional {
            append(status)
        }

        for status in defaults {
            append(status)
            append(status.capitalized)
            append(status.uppercased())
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
        queuedKeys: inout Set<String>
    ) {
        for status in additions {
            let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let key = statusCandidateKey(trimmed)
            guard !queuedKeys.contains(key) else { continue }

            queuedKeys.insert(key)
            statuses.append(trimmed)
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

struct CreateVendorRequest: Encodable {
    let name: String
    let phone: String?
}

struct CreateVendorResponse: Decodable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
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

struct CreatePartRequest: Encodable {
    let name: String
    let quantity: Int
    let partNumber: String?
    let wholesaleCostCents: Int
    let vendorId: String
    let purchaseOrderId: String?

    enum CodingKeys: String, CodingKey {
        case name
        case quantity
        case partNumber = "part_number"
        case wholesaleCostCents = "wholesale_cost_cents"
        case vendorId = "vendor_id"
        case purchaseOrderId = "purchase_order_id"
    }
}

struct CreatePartResponse: Decodable {
    let id: String
    let name: String
}

struct CreateFeeRequest: Encodable {
    let description: String
    let amountCents: Int
    let purchaseOrderId: String?

    enum CodingKeys: String, CodingKey {
        case description
        case amountCents = "amount_cents"
        case purchaseOrderId = "purchase_order_id"
    }
}

struct CreateTireRequest: Encodable {
    let description: String
    let quantity: Int
    let costCents: Int
    let vendorId: String?
    let purchaseOrderId: String?

    enum CodingKeys: String, CodingKey {
        case description
        case quantity
        case costCents = "cost_cents"
        case vendorId = "vendor_id"
        case purchaseOrderId = "purchase_order_id"
    }
}

struct CreatePurchaseOrderLineItemRequest: Encodable, Hashable {
    let description: String
    let quantity: Int
    let unitCostCents: Int
    let name: String?
    let partNumber: String?
    let costCents: Int?
    let unitCost: Decimal?

    init(
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

struct CreatePurchaseOrderPartRequest: Encodable, Hashable {
    let name: String
    let quantity: Int
    let costCents: Int
    let number: String?
    let description: String?
    let partNumber: String?

    enum CodingKeys: String, CodingKey {
        case name
        case quantity
        case costCents = "cost_cents"
        case number
        case description
        case partNumber = "part_number"
    }
}

struct CreatePurchaseOrderFeeRequest: Encodable, Hashable {
    let name: String
    let amountCents: Int
    let description: String?

    enum CodingKeys: String, CodingKey {
        case name
        case amountCents = "amount_cents"
        case description
    }
}

struct CreatePurchaseOrderTireRequest: Encodable, Hashable {
    let name: String
    let quantity: Int
    let costCents: Int
    let number: String?
    let description: String?
    let partNumber: String?

    enum CodingKeys: String, CodingKey {
        case name
        case quantity
        case costCents = "cost_cents"
        case number
        case description
        case partNumber = "part_number"
    }
}

struct CreatePurchaseOrderRequest: Encodable {
    let vendorId: String
    let invoiceNumber: String?
    let status: String?
    let purchaseOrderId: String?
    let orderId: String?
    let lineItems: [CreatePurchaseOrderLineItemRequest]
    let parts: [CreatePurchaseOrderPartRequest]
    let fees: [CreatePurchaseOrderFeeRequest]
    let tires: [CreatePurchaseOrderTireRequest]

    init(
        vendorId: String,
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

struct CreatedResourceResponse: Decodable {
    let id: String
}

struct CreatePurchaseOrderResponse: Decodable {
    let id: String
    let vendorId: String?
    let status: String?

    init(id: String, vendorId: String?, status: String?) {
        self.id = id
        self.vendorId = vendorId
        self.status = status
    }

    init(from decoder: Decoder) throws {
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
                "poId",
                "number",
                "po_number",
                "poNumber"
            ],
            in: root
        )
        let resolvedVendorId = Self.firstString(keys: ["vendor_id", "vendorId"], in: root)
        let resolvedStatus = Self.firstString(keys: ["status"], in: root)

        // Some tenants return only success/message for writes; avoid false decode failures on HTTP 2xx.
        self.id = resolvedId ?? "accepted"
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

struct PurchaseOrderResponse: Decodable, Identifiable {
    enum LineItemKind: String, Hashable {
        case part
        case fee
        case tire
    }

    struct LineItem: Hashable {
        let name: String
        let quantity: Int
        let costCents: Int
        let partNumber: String?
        let kind: LineItemKind
    }

    let id: String
    let vendorId: String?
    let vendorName: String?
    let number: String?
    let orderId: String?
    let status: String
    let parts: [LineItem]
    let fees: [LineItem]
    let tires: [LineItem]

    var isDraft: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "draft"
    }

    var allLineItems: [LineItem] {
        parts + fees + tires
    }

    init(
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

    init(from decoder: Decoder) throws {
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
                    name: name,
                    quantity: max(1, quantity),
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

struct OrderSummary: Decodable, Identifiable {
    let id: String
    let number: String?
    let orderName: String?
    let customerName: String?

    var displayTitle: String {
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

    init(id: String, number: String?, orderName: String? = nil, customerName: String? = nil) {
        self.id = id
        self.number = number
        self.orderName = orderName
        self.customerName = customerName
    }

    init(from decoder: Decoder) throws {
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

struct ServiceSummary: Decodable, Identifiable {
    let id: String
    let name: String?
}

struct VendorSummary: Decodable, Identifiable {
    let id: String
    let name: String
}
