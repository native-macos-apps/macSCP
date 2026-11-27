import Foundation

/// Coordinates connection metadata changes with their Keychain credentials.
@MainActor
struct ConnectionPersistence {
    private struct Credentials {
        var password: String?
        var s3: S3Credentials?
    }

    // Commander windows can have separate view models for the same profile.
    private static var writingProfiles: Set<UUID> = []

    let repository: ConnectionRepositoryProtocol
    let keychain: KeychainServiceProtocol

    func save(_ connection: Connection, password: String?) async throws {
        try await writeCredentials(for: connection.id, desired: { previous in
            credentials(for: connection, password: password, previous: previous)
        }) {
            try await repository.save(connection)
        }
    }

    func update(_ connection: Connection, password: String?) async throws {
        try await writeCredentials(for: connection.id, desired: { previous in
            credentials(for: connection, password: password, previous: previous)
        }) {
            try await repository.update(connection)
        }
    }

    func delete(id: UUID) async throws {
        try await writeCredentials(for: id, desired: { _ in Credentials() }) {
            try await repository.delete(id: id)
        }
    }

    private func credentials(for connection: Connection, password: String?, previous: Credentials) -> Credentials {
        guard connection.savePassword else { return Credentials() }
        let supplied = password.flatMap { $0.isEmpty ? nil : $0 }
        if connection.connectionType == .s3 {
            let secret = supplied ?? previous.s3?.secretAccessKey
            return Credentials(s3: secret.map {
                S3Credentials(accessKeyId: connection.username, secretAccessKey: $0)
            })
        }
        guard connection.authMethod == .password else { return Credentials() }
        return Credentials(password: supplied ?? previous.password)
    }

    private func writeCredentials(
        for id: UUID,
        desired: (Credentials) -> Credentials,
        commit: () async throws -> Void
    ) async throws {
        guard Self.writingProfiles.insert(id).inserted else {
            throw AppError.saveFailed("Another change to this connection is in progress. Try again.")
        }
        defer { Self.writingProfiles.remove(id) }

        let previous = Credentials(
            password: try keychain.readPassword(for: id),
            s3: try keychain.readS3Credentials(for: id)
        )
        let next = desired(previous)
        var restore: [() throws -> Void] = []

        do {
            if next.password != previous.password {
                try setPassword(next.password, for: id)
                restore.append { try setPassword(previous.password, for: id) }
            }
            if next.s3?.accessKeyId != previous.s3?.accessKeyId ||
                next.s3?.secretAccessKey != previous.s3?.secretAccessKey {
                try setS3Credentials(next.s3, for: id)
                restore.append { try setS3Credentials(previous.s3, for: id) }
            }

            try await commit()
        } catch {
            var failedToRestore = false
            for action in restore.reversed() {
                do {
                    try action()
                } catch {
                    failedToRestore = true
                    logError("Could not restore credentials for connection \(id): \(error)", category: .keychain)
                }
            }
            if failedToRestore {
                throw AppError.unknown("\(error.localizedDescription) The previous Keychain credentials could not be fully restored. Verify the saved credentials before reconnecting.")
            }
            throw error
        }
    }

    private func setPassword(_ password: String?, for id: UUID) throws {
        if let password {
            try keychain.savePassword(password, for: id)
        } else {
            try keychain.deletePassword(for: id)
        }
    }

    private func setS3Credentials(_ credentials: S3Credentials?, for id: UUID) throws {
        if let credentials {
            try keychain.saveS3Credentials(credentials, for: id)
        } else {
            try keychain.deleteS3Credentials(for: id)
        }
    }
}
