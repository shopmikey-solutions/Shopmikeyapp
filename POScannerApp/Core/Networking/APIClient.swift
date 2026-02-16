//
//  APIClient.swift
//  POScannerApp
//

import Foundation

/// URLSession-backed client with strict Bearer auth and safe 429 Retry-After handling (single retry).
final class APIClient {
    enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
    }

    typealias TokenProvider = @Sendable () throws -> String
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let urlSession: URLSession
    private let tokenProvider: TokenProvider
    private let sleeper: Sleeper
    private let diagnosticsRecorder: NetworkDiagnosticsRecorder

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(
        baseURL: URL,
        urlSession: URLSession = .shared,
        tokenProvider: @escaping TokenProvider,
        sleeper: @escaping Sleeper = APIClient.defaultSleeper,
        diagnosticsRecorder: NetworkDiagnosticsRecorder = .shared
    ) {
        // `baseURL` is intentionally ignored by the hardened client. Callers should supply full URLs.
        _ = baseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
        self.sleeper = sleeper
        self.diagnosticsRecorder = diagnosticsRecorder
    }

    func perform<Response: Decodable>(
        _ method: HTTPMethod,
        url: URL,
        body: Data? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        request = try authorize(request)

        #if DEBUG
        print("➡️ Request: \(request.url?.absoluteString ?? "")")
        #endif

        let (data, httpResponse) = try await send(request, didRetryOn429: false)
        do {
            let decoded = try decoder.decode(Response.self, from: data)
            await diagnosticsRecorder.record(
                NetworkDiagnosticsEntry(
                    method: method.rawValue,
                    url: url.absoluteString,
                    statusCode: httpResponse.statusCode,
                    requestBodyPreview: sanitizedPreview(from: body),
                    responseBodyPreview: sanitizedPreview(from: data),
                    errorSummary: nil
                )
            )
            return decoded
        } catch {
            await diagnosticsRecorder.record(
                NetworkDiagnosticsEntry(
                    method: method.rawValue,
                    url: url.absoluteString,
                    statusCode: httpResponse.statusCode,
                    requestBodyPreview: sanitizedPreview(from: body),
                    responseBodyPreview: sanitizedPreview(from: data),
                    errorSummary: "Decoding failed"
                )
            )
            throw APIError.decodingFailed
        }
    }

    // MARK: - Internals

    private func authorize(_ request: URLRequest) throws -> URLRequest {
        let token = (try? tokenProvider())
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let token, !token.isEmpty else {
            throw APIError.missingToken
        }

        var authorized = request
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return authorized
    }

    private func send(_ request: URLRequest, didRetryOn429: Bool) async throws -> (Data, HTTPURLResponse) {
        let dataAndResponse: (Data, URLResponse)
        do {
            dataAndResponse = try await urlSession.data(for: request)
        } catch {
            await diagnosticsRecorder.record(
                entry(
                    for: request,
                    statusCode: nil,
                    responseData: nil,
                    errorSummary: error.localizedDescription
                )
            )
            throw APIError.network(error)
        }

        let (data, response) = dataAndResponse
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network(URLError(.badServerResponse))
        }

        if http.statusCode == 429 {
            if !didRetryOn429,
               let retryAfter = http.value(forHTTPHeaderField: "Retry-After"),
               let delay = Double(retryAfter) {
                try await sleeper(delay)
                return try await send(request, didRetryOn429: true)
            }
            await diagnosticsRecorder.record(entry(for: request, statusCode: http.statusCode, responseData: data, errorSummary: "Rate limited"))
            throw APIError.rateLimited
        }

        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401:
            await diagnosticsRecorder.record(entry(for: request, statusCode: http.statusCode, responseData: data, errorSummary: "Unauthorized"))
            throw APIError.unauthorized
        case 500...599:
            #if DEBUG
            logFailedResponse(statusCode: http.statusCode, request: request, data: data)
            #endif
            await diagnosticsRecorder.record(entry(for: request, statusCode: http.statusCode, responseData: data, errorSummary: "Server error"))
            throw APIError.serverError(http.statusCode)
        default:
            // Deterministic: treat any other non-2xx as a server error code.
            #if DEBUG
            logFailedResponse(statusCode: http.statusCode, request: request, data: data)
            #endif
            await diagnosticsRecorder.record(entry(for: request, statusCode: http.statusCode, responseData: data, errorSummary: "HTTP \(http.statusCode)"))
            throw APIError.serverError(http.statusCode)
        }
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return try encoder.encode(value)
        } catch {
            throw APIError.encodingFailed
        }
    }

    static func defaultSleeper(_ seconds: TimeInterval) async throws {
        let clamped = max(0, seconds)
        let nanosDouble = clamped * 1_000_000_000
        let nanos = UInt64(min(nanosDouble, Double(UInt64.max)))
        try await Task.sleep(nanoseconds: nanos)
    }

    private func entry(
        for request: URLRequest,
        statusCode: Int?,
        responseData: Data?,
        errorSummary: String?
    ) -> NetworkDiagnosticsEntry {
        NetworkDiagnosticsEntry(
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "(unknown url)",
            statusCode: statusCode,
            requestBodyPreview: sanitizedPreview(from: request.httpBody),
            responseBodyPreview: sanitizedPreview(from: responseData),
            errorSummary: errorSummary
        )
    }

    private func sanitizedPreview(from data: Data?) -> String? {
        guard let data else { return nil }
        guard !data.isEmpty else { return nil }
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        // Keep enough payload for full request/response diagnostics during sandbox schema debugging.
        return String(raw.prefix(20_000))
    }

    #if DEBUG
    private func logFailedResponse(statusCode: Int, request: URLRequest, data: Data) {
        let url = request.url?.absoluteString ?? "(unknown url)"
        print("⬅️ Response \(statusCode): \(url)")
        guard let preview = sanitizedPreview(from: data) else {
            return
        }
        print("⬅️ Body: \(preview)")
    }
    #endif
}

struct NetworkDiagnosticsEntry: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let method: String
    let url: String
    let statusCode: Int?
    let requestBodyPreview: String?
    let responseBodyPreview: String?
    let errorSummary: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: String,
        url: String,
        statusCode: Int?,
        requestBodyPreview: String?,
        responseBodyPreview: String?,
        errorSummary: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.requestBodyPreview = requestBodyPreview
        self.responseBodyPreview = responseBodyPreview
        self.errorSummary = errorSummary
    }

    var oneLineSummary: String {
        let status = statusCode.map(String.init) ?? "n/a"
        if let errorSummary, !errorSummary.isEmpty {
            return "[\(status)] \(method) \(url) - \(errorSummary)"
        }
        return "[\(status)] \(method) \(url)"
    }

    var isFailure: Bool {
        if let statusCode {
            return !(200...299).contains(statusCode)
        }
        return errorSummary != nil
    }
}

actor NetworkDiagnosticsRecorder {
    static let shared = NetworkDiagnosticsRecorder()

    private let maxEntries: Int
    private var entries: [NetworkDiagnosticsEntry]

    init(maxEntries: Int = 300) {
        self.maxEntries = maxEntries
        self.entries = []
    }

    func record(_ entry: NetworkDiagnosticsEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    func latest(limit: Int = 120) -> [NetworkDiagnosticsEntry] {
        Array(entries.prefix(max(0, limit)))
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    func exportText(limit: Int = 200) -> String {
        let clipped = Array(entries.prefix(max(0, limit)))
        if clipped.isEmpty {
            return "No captured network entries."
        }

        return clipped.map { entry in
            var lines: [String] = []
            lines.append("\(entry.timestamp.formatted(date: .abbreviated, time: .standard)) | \(entry.oneLineSummary)")
            if let requestBodyPreview = entry.requestBodyPreview, !requestBodyPreview.isEmpty {
                lines.append("request: \(requestBodyPreview)")
            }
            if let responseBodyPreview = entry.responseBodyPreview, !responseBodyPreview.isEmpty {
                lines.append("response: \(responseBodyPreview)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    func latestFailure(
        urlContains: String? = nil,
        method: String? = nil,
        since: Date? = nil
    ) -> NetworkDiagnosticsEntry? {
        entries.first { entry in
            guard entry.isFailure else { return false }

            if let urlContains, !entry.url.localizedCaseInsensitiveContains(urlContains) {
                return false
            }

            if let method,
               entry.method.caseInsensitiveCompare(method) != .orderedSame {
                return false
            }

            if let since, entry.timestamp < since {
                return false
            }

            return true
        }
    }

    func latestFailureSummary(since: Date? = nil) -> String? {
        guard let failure = latestFailure(since: since) else {
            return nil
        }
        var summary = failure.oneLineSummary
        if let requestBodyPreview = failure.requestBodyPreview, !requestBodyPreview.isEmpty {
            summary += " | request: \(requestBodyPreview)"
        }
        if let responseBodyPreview = failure.responseBodyPreview, !responseBodyPreview.isEmpty {
            summary += " | response: \(responseBodyPreview)"
        }
        return summary
    }
}
