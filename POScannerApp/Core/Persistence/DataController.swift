//
//  DataController.swift
//  POScannerApp
//

import CoreData
import Foundation

/// Core Data stack owner.
final class DataController {
    let container: NSPersistentContainer
    private(set) var loadError: Error?
    private let loadLock = NSLock()
    private var isLoaded: Bool = false
    private var loadContinuations: [CheckedContinuation<Void, Never>] = []

    init(inMemory: Bool = false) {
        guard let modelURL = Bundle.main.url(forResource: "POScannerApp", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Failed to load Core Data model")
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
                description.shouldMigrateStoreAutomatically = true
                description.shouldInferMappingModelAutomatically = true
            }
        }

        container.loadPersistentStores { [weak self] _, error in
            guard let self else { return }
            if let error {
                self.loadError = error
            }

            self.loadLock.lock()
            self.isLoaded = true
            let continuations = self.loadContinuations
            self.loadContinuations.removeAll()
            self.loadLock.unlock()
            for cont in continuations {
                cont.resume()
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    /// Await the persistent store load completion. Useful for tests.
    func waitUntilLoaded() async {
        loadLock.lock()
        if isLoaded {
            loadLock.unlock()
            return
        }
        loadLock.unlock()

        await withCheckedContinuation { cont in
            loadLock.lock()
            if isLoaded {
                loadLock.unlock()
                cont.resume()
                return
            }
            loadContinuations.append(cont)
            loadLock.unlock()
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
