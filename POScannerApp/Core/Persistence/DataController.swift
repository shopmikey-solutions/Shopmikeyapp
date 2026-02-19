//
//  DataController.swift
//  POScannerApp
//

import CoreData
import Foundation
import os

/// Core Data stack owner.
final class DataController {
    private static let logger = Logger(subsystem: "com.mikey.POScannerApp", category: "Startup.CoreData")

    let container: NSPersistentContainer
    private(set) var loadError: Error?
    private let loadLock = NSLock()
    private var isLoaded: Bool = false
    private var loadContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let loadWaitTimeout: TimeInterval = 6.0
    private let loadStartedAt: Date = Date()

    init(inMemory: Bool = false) {
        Self.logger.info("Persistent store initialization started. inMemory=\(inMemory, privacy: .public)")
        let model: NSManagedObjectModel
        do {
            model = try Self.resolveModel()
        } catch {
            loadError = error
            model = NSManagedObjectModel()
            Self.logger.error("Core Data model resolution failed: \(String(describing: error), privacy: .public)")
        }

        self.container = NSPersistentContainer(name: "POScannerApp", managedObjectModel: model)

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            description.shouldAddStoreAsynchronously = false
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            container.persistentStoreDescriptions = [description]
        } else {
            for description in container.persistentStoreDescriptions {
                // Keep launch responsive on device; views already await readiness where needed.
                description.shouldAddStoreAsynchronously = true
                description.shouldMigrateStoreAutomatically = true
                description.shouldInferMappingModelAutomatically = true
            }
        }

        container.loadPersistentStores { [weak self] _, error in
            guard let self else { return }
            self.markLoaded(error: error)
        }
        scheduleLoadTimeoutFallback()

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    private static func resolveModel() throws -> NSManagedObjectModel {
        if let modelURL = Bundle.main.url(forResource: "POScannerApp", withExtension: "momd"),
           let model = NSManagedObjectModel(contentsOf: modelURL) {
            return model
        }

        if let modelURL = Bundle.main.url(forResource: "POScannerApp", withExtension: "mom"),
           let model = NSManagedObjectModel(contentsOf: modelURL) {
            return model
        }

        if let merged = NSManagedObjectModel.mergedModel(from: [Bundle.main]) {
            return merged
        }

        throw NSError(
            domain: "POScannerApp.DataController",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to locate POScannerApp Core Data model."]
        )
    }

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    /// Await the persistent store load completion. Useful for tests.
    func waitUntilLoaded(timeout: TimeInterval = 5.0) async {
        loadLock.lock()
        if isLoaded {
            loadLock.unlock()
            return
        }
        loadLock.unlock()

        let token = UUID()
        await withCheckedContinuation { cont in
            loadLock.lock()
            if isLoaded {
                loadLock.unlock()
                cont.resume()
                return
            }
            loadContinuations[token] = cont
            loadLock.unlock()
            Self.logger.debug("Registered persistent store wait continuation. token=\(token.uuidString, privacy: .public)")

            guard timeout > 0 else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resumeLoadContinuationIfPending(token: token)
            }
        }
    }

    private func markLoaded(error: Error?) {
        loadLock.lock()
        guard !isLoaded else {
            loadLock.unlock()
            return
        }

        if let error, loadError == nil {
            loadError = error
        }
        isLoaded = true
        let continuations = loadContinuations.values
        let continuationCount = continuations.count
        loadContinuations.removeAll()
        loadLock.unlock()

        let elapsed = Date().timeIntervalSince(loadStartedAt)
        let elapsedText = String(format: "%.2f", elapsed)
        if let error {
            Self.logger.error(
                "Persistent store load finished with error after \(elapsedText, privacy: .public)s. waitingContinuations=\(continuationCount, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        } else {
            Self.logger.info(
                "Persistent store load succeeded after \(elapsedText, privacy: .public)s. waitingContinuations=\(continuationCount, privacy: .public)"
            )
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    private func resumeLoadContinuationIfPending(token: UUID) {
        loadLock.lock()
        guard let continuation = loadContinuations.removeValue(forKey: token) else {
            loadLock.unlock()
            return
        }
        loadLock.unlock()
        Self.logger.warning("Persistent store wait continuation timed out. token=\(token.uuidString, privacy: .public)")
        continuation.resume()
    }

    private func scheduleLoadTimeoutFallback() {
        let timeout = loadWaitTimeout
        guard timeout > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            Self.logger.error("Persistent store load timeout fallback triggered at \(Int(timeout), privacy: .public)s")
            self.markLoaded(error: NSError(
                domain: "POScannerApp.DataController",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Persistent store load timed out after \(Int(timeout))s."]
            ))
        }
    }
}

enum CoreDataInsertError: Error, Equatable {
    case missingEntity(String)
}

extension NSManagedObjectContext {
    /// Insert a managed object using the entity description resolved from *this* context.
    ///
    /// Avoids `+[NSManagedObject entity]` ambiguity when multiple models are loaded (e.g. app + test host).
    func insertObject<T: NSManagedObject>(_ type: T.Type) throws -> T {
        let entityName = String(describing: type)
        guard let entity = NSEntityDescription.entity(forEntityName: entityName, in: self) else {
            throw CoreDataInsertError.missingEntity(entityName)
        }
        return T(entity: entity, insertInto: self)
    }
}
