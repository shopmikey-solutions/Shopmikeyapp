import Foundation
import OSLog

enum NetworkingLogger {
    static let logger = Logger(subsystem: "com.shopmikey", category: "networking")

    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "cookie",
        "set-cookie",
        "x-api-key"
    ]

    static func sanitizedURLString(_ url: URL?) -> String {
        guard let url else {
            return "(unknown-url)"
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "(invalid-url)"
        }

        components.query = nil
        components.fragment = nil

        let scheme = components.scheme ?? url.scheme ?? "https"
        let host = components.host ?? url.host ?? "(unknown-host)"
        let portSuffix: String
        if let port = components.port {
            portSuffix = ":\(port)"
        } else {
            portSuffix = ""
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return "\(scheme)://\(host)\(portSuffix)\(path)"
    }

    static func redactedHeaders(for request: URLRequest) -> [String: String] {
        redactedHeaders(from: request.allHTTPHeaderFields ?? [:])
    }

    static func redactedHeaders(from headers: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (name, value) in headers {
            if sensitiveHeaderNames.contains(name.lowercased()) {
                continue
            }
            sanitized[name] = value
        }
        return sanitized
    }

    static func logRequestStart(
        requestID: UUID,
        method: String,
        url: URL?,
        timeout: TimeInterval,
        attempt: Int,
        headers: [String: String]
    ) {
        let endpoint = sanitizedURLString(url)
        let timeoutMillis = max(0, Int((timeout * 1_000).rounded()))
        logger.log(
            "request_start id=\(requestID.uuidString, privacy: .public) method=\(method, privacy: .public) endpoint=\(endpoint, privacy: .public) timeout_ms=\(timeoutMillis, privacy: .public) attempt=\(attempt, privacy: .public) headers=\(headers.count, privacy: .public)"
        )
    }

    static func logRequestEnd(
        requestID: UUID,
        method: String,
        url: URL?,
        statusCode: Int,
        durationMillis: Int,
        attempt: Int
    ) {
        let endpoint = sanitizedURLString(url)
        logger.log(
            "request_end id=\(requestID.uuidString, privacy: .public) method=\(method, privacy: .public) endpoint=\(endpoint, privacy: .public) status=\(statusCode, privacy: .public) duration_ms=\(durationMillis, privacy: .public) attempt=\(attempt, privacy: .public)"
        )
    }

    static func logRequestError(
        requestID: UUID,
        method: String,
        url: URL?,
        error: Error,
        durationMillis: Int,
        attempt: Int
    ) {
        let endpoint = sanitizedURLString(url)
        let nsError = error as NSError
        logger.error(
            "request_error id=\(requestID.uuidString, privacy: .public) method=\(method, privacy: .public) endpoint=\(endpoint, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) duration_ms=\(durationMillis, privacy: .public) attempt=\(attempt, privacy: .public)"
        )
    }
}
