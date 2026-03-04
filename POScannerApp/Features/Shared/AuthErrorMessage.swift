//
//  AuthErrorMessage.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreNetworking

func authErrorMessage(for error: Error, isAuthConfigured: Bool) -> String? {
    if !isAuthConfigured {
        return "API key missing. Add it in Settings."
    }

    if let apiError = error as? APIError {
        switch apiError {
        case .missingToken:
            return "API key missing. Add it in Settings."
        case .unauthorized:
            return "API key invalid or expired."
        case .serverError(let code) where code == 401 || code == 403:
            return "API key invalid or expired."
        default:
            return nil
        }
    }

    return nil
}
