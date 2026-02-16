//
//  SecureStorage.swift
//  POScannerApp
//

import Foundation
import LocalAuthentication

/// Optional biometric gate for accessing sensitive values.
final class SecureStorage {
    enum SecureStorageError: Error {
        case biometricsUnavailable
        case authenticationFailed
    }

    private let keychainService: KeychainService

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
    }

    func retrieveTokenRequiringBiometrics(reason: String = "Authenticate to access the stored API key.") async throws -> String {
        let context = LAContext()

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw SecureStorageError.biometricsUnavailable
        }

        let ok = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )

        guard ok else { throw SecureStorageError.authenticationFailed }
        return try keychainService.retrieveToken()
    }
}

