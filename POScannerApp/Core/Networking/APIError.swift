//
//  APIError.swift
//  POScannerApp
//

import Foundation

/// App-wide networking errors. Never include secrets (tokens) in these errors.
enum APIError: Error {
    case invalidURL
    case encodingFailed
    case decodingFailed
    case network(Error)
    case unauthorized
    case rateLimited
    case serverError(Int)
    case missingToken
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL."
        case .encodingFailed:
            return "Failed to encode request."
        case .decodingFailed:
            return "Failed to decode response."
        case .network:
            return "Network error."
        case .unauthorized:
            return "Unauthorized."
        case .rateLimited:
            return "Rate limited."
        case .serverError(let code):
            return "Server error (\(code))."
        case .missingToken:
            return "Missing API key."
        }
    }
}

