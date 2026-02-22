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
        case userCancelled
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

    /// Retrieves the token requiring device authentication (biometrics or passcode as fallback).
    /// Uses .deviceOwnerAuthentication so the system can prompt for Face ID/Touch ID and fallback to passcode when needed.
    func retrieveTokenRequiringAuthentication(reason: String = "Authenticate to access the stored API key.") async throws -> String {
        let context = LAContext()

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw SecureStorageError.biometricsUnavailable
        }

        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            guard ok else { throw SecureStorageError.authenticationFailed }
        } catch let laError as LAError {
            if laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel {
                throw SecureStorageError.userCancelled
            }
            throw SecureStorageError.authenticationFailed
        } catch {
            throw SecureStorageError.authenticationFailed
        }

        return try keychainService.retrieveToken()
    }
}
