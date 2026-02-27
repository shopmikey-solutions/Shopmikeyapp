//
//  DiagnosticCode.swift
//  POScannerApp
//

import Foundation

enum DiagnosticSeverity: String, Codable, Hashable {
    case info
    case warning
    case error
}

enum DiagnosticCode: String, CaseIterable, Codable, Hashable {
    // AUTH
    case authMissingToken = "SMK-AUTH-MISSING-TOKEN"
    case authUnauthorized401 = "SMK-AUTH-UNAUTHORIZED-401"
    case authForbidden403 = "SMK-AUTH-FORBIDDEN-403"
    case authChallengeFailed = "SMK-AUTH-CHALLENGE-FAILED"

    // NET
    case netTimeoutRequest = "SMK-NET-TIMEOUT-REQUEST"
    case netConnectivityUnreachable = "SMK-NET-CONNECTIVITY-UNREACHABLE"
    case netRate429 = "SMK-NET-RATE-429"
    case netUnknownError = "SMK-NET-UNKNOWN-ERROR"

    // API
    case apiDecodeBadJSON = "SMK-API-DECODE-BAD_JSON"
    case apiNotFound404 = "SMK-API-NOTFOUND-404"
    case apiConflict409 = "SMK-API-CONFLICT-409"
    case apiValidate422 = "SMK-API-VALIDATE-422"
    case apiServer5xx = "SMK-API-SERVER-5XX"
    case apiUnknownError = "SMK-API-UNKNOWN-ERROR"

    // OCR / PARSE / SYNC / CFG
    case ocrPipelineFailed = "SMK-OCR-PIPELINE-FAILED"
    case parseExtractFailed = "SMK-PARSE-EXTRACT-FAILED"
    case syncQueueFailed = "SMK-SYNC-QUEUE-FAILED"
    case cfgURLInvalid = "SMK-CFG-URL-INVALID"
    case cfgEnvironmentMissing = "SMK-CFG-ENV-MISSING"

    // SUBMIT
    case submitValidatePayload = "SMK-SUBMIT-VALIDATE-PAYLOAD"
    case submitValidateVendor = "SMK-SUBMIT-VALIDATE-VENDOR"
    case submitValidateNoItems = "SMK-SUBMIT-VALIDATE-NO_ITEMS"
    case submitVendorResolve = "SMK-SUBMIT-VENDOR-RESOLVE"
    case submitPOEncode = "SMK-SUBMIT-ENCODE-PO_CREATE"
    case submitPOCreate = "SMK-SUBMIT-PO-CREATE"
    case submitFallbackExhausted = "SMK-SUBMIT-FALLBACK-EXHAUSTED"
    case submitUnknownError = "SMK-SUBMIT-UNKNOWN-ERROR"

    var domain: String {
        codeComponents.domain
    }

    var category: String {
        codeComponents.category
    }

    var detail: String? {
        codeComponents.detail
    }

    var userFacingTitle: String {
        switch self {
        case .authMissingToken:
            return "Missing API Key"
        case .authUnauthorized401:
            return "Unauthorized"
        case .authForbidden403:
            return "Forbidden"
        case .authChallengeFailed:
            return "Authentication Failed"

        case .netTimeoutRequest:
            return "Request Timeout"
        case .netConnectivityUnreachable:
            return "Network Unreachable"
        case .netRate429:
            return "Rate Limited"
        case .netUnknownError:
            return "Network Error"

        case .apiDecodeBadJSON:
            return "Response Decode Error"
        case .apiNotFound404:
            return "Resource Not Found"
        case .apiConflict409:
            return "Request Conflict"
        case .apiValidate422:
            return "Validation Error"
        case .apiServer5xx:
            return "Server Error"
        case .apiUnknownError:
            return "API Error"

        case .ocrPipelineFailed:
            return "OCR Failure"
        case .parseExtractFailed:
            return "Parse Failure"
        case .syncQueueFailed:
            return "Sync Queue Failure"
        case .cfgURLInvalid:
            return "Invalid Configuration URL"
        case .cfgEnvironmentMissing:
            return "Missing Environment Configuration"

        case .submitValidatePayload:
            return "Submission Validation Failed"
        case .submitValidateVendor:
            return "Vendor Validation Failed"
        case .submitValidateNoItems:
            return "No Submittable Items"
        case .submitVendorResolve:
            return "Vendor Resolution Failed"
        case .submitPOEncode:
            return "Submission Encoding Failed"
        case .submitPOCreate:
            return "Purchase Order Creation Failed"
        case .submitFallbackExhausted:
            return "Submission Fallback Exhausted"
        case .submitUnknownError:
            return "Submission Failed"
        }
    }

    var userFacingMessage: String {
        switch self {
        case .authMissingToken:
            return "No API key is configured."
        case .authUnauthorized401:
            return "The API key is not authorized."
        case .authForbidden403:
            return "The account does not have permission for this action."
        case .authChallengeFailed:
            return "Authentication could not be completed."

        case .netTimeoutRequest:
            return "The request timed out."
        case .netConnectivityUnreachable:
            return "Shopmonkey could not be reached."
        case .netRate429:
            return "Too many requests were sent."
        case .netUnknownError:
            return "A network issue occurred."

        case .apiDecodeBadJSON:
            return "The response could not be decoded."
        case .apiNotFound404:
            return "The requested resource was not found."
        case .apiConflict409:
            return "The request conflicts with existing data."
        case .apiValidate422:
            return "The server rejected one or more fields."
        case .apiServer5xx:
            return "Shopmonkey reported a server-side error."
        case .apiUnknownError:
            return "An API error occurred."

        case .ocrPipelineFailed:
            return "The scan could not be processed."
        case .parseExtractFailed:
            return "The document text could not be parsed."
        case .syncQueueFailed:
            return "The sync queue could not process pending operations."
        case .cfgURLInvalid:
            return "A required endpoint URL is invalid."
        case .cfgEnvironmentMissing:
            return "A required environment configuration value is missing."

        case .submitValidatePayload:
            return "The submission payload did not pass validation."
        case .submitValidateVendor:
            return "The vendor details did not pass validation."
        case .submitValidateNoItems:
            return "No valid line items were available for submission."
        case .submitVendorResolve:
            return "A matching vendor could not be resolved."
        case .submitPOEncode:
            return "The submission payload could not be encoded."
        case .submitPOCreate:
            return "The purchase order could not be created."
        case .submitFallbackExhausted:
            return "Submission fallback attempts were exhausted."
        case .submitUnknownError:
            return "An unknown submission error occurred."
        }
    }

    var suggestedAction: String? {
        switch self {
        case .authMissingToken:
            return "Add a valid API key in Settings."
        case .authUnauthorized401, .authForbidden403:
            return "Verify API key permissions in Shopmonkey."
        case .authChallengeFailed:
            return "Retry authentication and ensure biometrics are available."

        case .netTimeoutRequest, .netConnectivityUnreachable, .netUnknownError:
            return "Check connectivity and retry."
        case .netRate429:
            return "Wait briefly and retry."

        case .apiDecodeBadJSON, .apiUnknownError:
            return "Retry and contact support with this diagnostic ID if repeated."
        case .apiNotFound404:
            return "Confirm referenced IDs still exist."
        case .apiConflict409, .apiValidate422:
            return "Review payload fields and retry."
        case .apiServer5xx:
            return "Retry when the service stabilizes."

        case .ocrPipelineFailed, .parseExtractFailed:
            return "Retry scan with clearer input."
        case .syncQueueFailed:
            return "Open Settings diagnostics and retry sync."
        case .cfgURLInvalid, .cfgEnvironmentMissing:
            return "Verify app environment configuration."

        case .submitValidatePayload, .submitValidateVendor, .submitValidateNoItems:
            return "Correct form input and retry."
        case .submitVendorResolve:
            return "Select or create a vendor before retrying."
        case .submitPOEncode, .submitPOCreate:
            return "Retry submission and verify target order/service context."
        case .submitFallbackExhausted, .submitUnknownError:
            return "Retry later and share this ID with support if repeated."
        }
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .authChallengeFailed, .netRate429:
            return .warning
        case .ocrPipelineFailed, .parseExtractFailed:
            return .warning
        default:
            return .error
        }
    }

    static func forHTTPStatusCode(_ statusCode: Int) -> DiagnosticCode {
        switch statusCode {
        case 401:
            return .authUnauthorized401
        case 403:
            return .authForbidden403
        case 404:
            return .apiNotFound404
        case 409:
            return .apiConflict409
        case 422:
            return .apiValidate422
        case 429:
            return .netRate429
        case 500...599:
            return .apiServer5xx
        default:
            return .apiUnknownError
        }
    }

    static func forNetworkError(_ error: Error) -> DiagnosticCode {
        guard let urlError = error as? URLError else {
            return .netUnknownError
        }

        switch urlError.code {
        case .timedOut:
            return .netTimeoutRequest
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
            return .netConnectivityUnreachable
        default:
            return .netUnknownError
        }
    }

    static func from(error: Error) -> DiagnosticCode {
        if let apiError = error as? APIError {
            return apiError.diagnosticCode ?? .netUnknownError
        }
        if error is URLError {
            return forNetworkError(error)
        }
        return .submitUnknownError
    }

    private var codeComponents: (domain: String, category: String, detail: String?) {
        let segments = rawValue.split(separator: "-")
        guard segments.count >= 3 else {
            return (domain: "UNKNOWN", category: "UNKNOWN", detail: nil)
        }
        let domain = String(segments[1])
        let category = String(segments[2])
        let detail = segments.count > 3 ? segments[3...].joined(separator: "_") : nil
        return (domain: domain, category: category, detail: detail)
    }
}
