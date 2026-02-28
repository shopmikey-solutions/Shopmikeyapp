//
//  SyncEngine.swift
//  POScannerApp
//

import Foundation
import ShopmikeyCoreDiagnostics

public enum SyncExecutionResult: Sendable {
    case succeeded
    case failed(diagnosticCode: String?)
}

public enum SyncFailureDisposition: Sendable {
    case transient
    case permanent
}

public struct SyncRetryPolicy: Hashable, Sendable {
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    public var maxRetries: Int
    public var jitterFraction: Double

    public static let `default` = SyncRetryPolicy(
        baseDelay: 30,
        multiplier: 2,
        maxDelay: 600,
        maxRetries: 8,
        jitterFraction: 0.10
    )

    public init(
        baseDelay: TimeInterval,
        multiplier: Double,
        maxDelay: TimeInterval,
        maxRetries: Int,
        jitterFraction: Double
    ) {
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.maxRetries = maxRetries
        self.jitterFraction = jitterFraction
    }
}

public actor SyncEngine {
    public typealias OperationExecutor = @Sendable (SyncOperation) async -> SyncExecutionResult
    public typealias DateProvider = @Sendable () -> Date
    public typealias JitterProvider = @Sendable () -> Double

    private let queueStore: SyncOperationQueueStore
    private let executor: OperationExecutor
    private let retryPolicy: SyncRetryPolicy
    private let dateProvider: DateProvider
    private let jitterProvider: JitterProvider
    private var isRunning = false

    public init(
        queueStore: SyncOperationQueueStore,
        executor: @escaping OperationExecutor,
        retryPolicy: SyncRetryPolicy = .default,
        dateProvider: @escaping DateProvider = Date.init,
        jitterProvider: @escaping JitterProvider = { Double.random(in: -0.10...0.10) }
    ) {
        self.queueStore = queueStore
        self.executor = executor
        self.retryPolicy = retryPolicy
        self.dateProvider = dateProvider
        self.jitterProvider = jitterProvider
    }

    public func runOnce() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let now = dateProvider()
        let readyOperations = await queueStore.readyOperations(asOf: now)
        for operation in readyOperations where shouldProcess(operation) {
            await process(operation)
        }
    }

    public func hasReadyOperations() async -> Bool {
        let now = dateProvider()
        let readyOperations = await queueStore.readyOperations(asOf: now)
        return readyOperations.contains(where: shouldProcess)
    }

    private func process(_ operation: SyncOperation) async {
        await queueStore.markInProgress(id: operation.id)
        let result = await executor(operation)

        switch result {
        case .succeeded:
            await queueStore.markSucceeded(id: operation.id)
            await queueStore.remove(id: operation.id)

        case .failed(let diagnosticCode):
            let disposition = Self.failureDisposition(for: diagnosticCode)
            switch disposition {
            case .permanent:
                await queueStore.markFailed(
                    id: operation.id,
                    errorCode: diagnosticCode,
                    nextAttemptAt: nil
                )

            case .transient:
                await queueStore.incrementRetry(id: operation.id)
                guard let updated = await queueStore.operation(id: operation.id) else { return }

                if updated.retryCount >= retryPolicy.maxRetries {
                    await queueStore.markFailed(
                        id: updated.id,
                        errorCode: DiagnosticCode.submitFallbackExhausted.rawValue,
                        nextAttemptAt: nil
                    )
                    return
                }

                let delay = nextRetryDelay(forRetryCount: updated.retryCount)
                let nextAttempt = dateProvider().addingTimeInterval(delay)
                await queueStore.markPendingForRetry(
                    id: updated.id,
                    nextAttemptAt: nextAttempt,
                    errorCode: diagnosticCode
                )
            }
        }
    }

    private func shouldProcess(_ operation: SyncOperation) -> Bool {
        guard operation.retryCount < retryPolicy.maxRetries else { return false }

        if operation.status == .failed,
           Self.failureDisposition(for: operation.lastErrorCode) == .permanent {
            return false
        }

        return true
    }

    public func nextRetryDelay(forRetryCount retryCount: Int) -> TimeInterval {
        let baseDelay = Self.baseBackoffDelay(
            retryCount: retryCount,
            policy: retryPolicy
        )
        let boundedJitter = min(max(jitterProvider(), -retryPolicy.jitterFraction), retryPolicy.jitterFraction)
        let adjusted = baseDelay * (1 + boundedJitter)
        return max(0, adjusted)
    }

    public static func baseBackoffDelay(retryCount: Int, policy: SyncRetryPolicy = .default) -> TimeInterval {
        guard retryCount > 0 else { return 0 }
        let exponential = policy.baseDelay * pow(policy.multiplier, Double(retryCount - 1))
        return min(policy.maxDelay, exponential)
    }

    public static func failureDisposition(for diagnosticCode: String?) -> SyncFailureDisposition {
        guard let diagnosticCode else { return .transient }
        let code = diagnosticCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return .transient }

        switch code {
        case DiagnosticCode.authUnauthorized401.rawValue,
             DiagnosticCode.authForbidden403.rawValue,
             DiagnosticCode.submitValidatePayload.rawValue,
             DiagnosticCode.submitValidateVendor.rawValue,
             DiagnosticCode.submitValidateNoItems.rawValue,
             DiagnosticCode.submitFallbackExhausted.rawValue:
            return .permanent

        case DiagnosticCode.netConnectivityUnreachable.rawValue,
             DiagnosticCode.netTimeoutRequest.rawValue,
             DiagnosticCode.netRate429.rawValue,
             DiagnosticCode.apiServer5xx.rawValue:
            return .transient

        default:
            return .transient
        }
    }
}
