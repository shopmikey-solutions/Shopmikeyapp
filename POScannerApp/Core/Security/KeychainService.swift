//
//  KeychainService.swift
//  POScannerApp
//

import Foundation
import Security

/// Minimal Keychain wrapper for storing the Shopmonkey sandbox API token.
final class KeychainService: @unchecked Sendable {
    enum KeychainServiceError: Error {
        case invalidToken
        case itemNotFound
        case unexpectedStatus(OSStatus)
        case unexpectedData
    }

    #if DEBUG
    private func describeStatus(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "OSStatus(\(status)): \(message)"
        }
        return "OSStatus(\(status))"
    }
    #endif

    private let service: String
    private let account: String = "shopmonkey_api_token"
    private var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    init(service: String? = nil) {
        self.service = service ?? (Bundle.main.bundleIdentifier ?? "POScannerApp")
    }

    /// Stores (or updates) the API token using kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
    /// This allows background access after first unlock and prevents migration via backups to other devices.
    func storeToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainServiceError.invalidToken }
        guard let data = trimmed.data(using: .utf8) else { throw KeychainServiceError.unexpectedData }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            #if DEBUG
            print("KeychainService.storeToken update failed: \(describeStatus(updateStatus))")
            #endif
            throw KeychainServiceError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessibility

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            #if DEBUG
            print("KeychainService.storeToken add failed: \(describeStatus(addStatus))")
            #endif
            throw KeychainServiceError.unexpectedStatus(addStatus)
        }
    }

    func retrieveToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            throw KeychainServiceError.itemNotFound
        }

        guard status == errSecSuccess else {
            throw KeychainServiceError.unexpectedStatus(status)
        }

        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainServiceError.unexpectedData
        }

        return token
    }

    /// Retrieves the token if present; returns nil when not found.
    func retrieveTokenIfPresent() -> String? {
        do {
            return try retrieveToken()
        } catch KeychainServiceError.itemNotFound {
            return nil
        } catch {
            #if DEBUG
            print("KeychainService.retrieveTokenIfPresent error: \(error)")
            #endif
            return nil
        }
    }

    /// Returns true if a token exists in the Keychain without retrieving it.
    func tokenExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            #if DEBUG
            print("KeychainService.tokenExists unexpected status: \(describeStatus(status))")
            #endif
            return false
        }
    }

    func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }

        #if DEBUG
        print("KeychainService.deleteToken failed: \(describeStatus(status))")
        #endif
        throw KeychainServiceError.unexpectedStatus(status)
    }
}
