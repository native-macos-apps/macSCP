//
//  DataStore.swift
//  macSCP
//
//  SwiftData ModelContainer setup and management
//

import Foundation
import SwiftData

@MainActor
final class DataStore {
    static let shared = DataStore()

    let modelContainer: ModelContainer
    let isUsingInMemoryFallback: Bool
    let initializationError: String?

    init(inMemoryOnly: Bool = false) {
        let schema = Schema([
            ConnectionEntity.self,
            FolderEntity.self
        ])

        if !inMemoryOnly {
            do {
                let modelConfiguration = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    allowsSave: true
                )

                modelContainer = try ModelContainer(
                    for: schema,
                    configurations: [modelConfiguration]
                )
                isUsingInMemoryFallback = false
                initializationError = nil

                logInfo("DataStore initialized successfully", category: .database)
                return
            } catch {
                logError("Failed to initialize persistent DataStore, falling back to in-memory store: \(error)", category: .database)
                initializationError = error.localizedDescription
            }
        } else {
            initializationError = nil
        }

        // Fallback (or explicit in-memory store for previews/tests)
        let inMemoryConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true
        )

        do {
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [inMemoryConfiguration]
            )
            isUsingInMemoryFallback = !inMemoryOnly
            if isUsingInMemoryFallback {
                logWarning("DataStore running in temporary in-memory fallback mode; changes will not persist across launches.", category: .database)
            }
        } catch {
            // Unreachable for a valid static schema, but avoid crashing with an opaque error
            preconditionFailure("Unable to create even an in-memory ModelContainer: \(error)")
        }
    }

    var modelContext: ModelContext {
        modelContainer.mainContext
    }

    /// Creates a new background context for async operations
    func newBackgroundContext() -> ModelContext {
        ModelContext(modelContainer)
    }
}

// MARK: - Preview Support
extension DataStore {
    @MainActor
    static var preview: DataStore {
        DataStore(inMemoryOnly: true)
    }
}
