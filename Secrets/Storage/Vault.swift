import Foundation

/// Keychain-backed store for projects, services and credentials.
///
/// Credential metadata and secret values are separate items so a credential can be registered but
/// missing its value, e.g. when it was deleted on another Mac or iCloud Keychain hasn't caught up.
/// Everything here syncs; nothing is cached, so each read reflects the Keychain as it is now.
final class Vault: Sendable {
    let keychain: Keychain

    init(keychain: Keychain) {
        self.keychain = keychain
    }

    // MARK: Reading

    func projects() throws -> [Project] {
        try decodeAll(Project.self, kind: .project)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func services() throws -> [Service] {
        try decodeAll(Service.self, kind: .service)
    }

    func credentials() throws -> [Credential] {
        try decodeAll(Credential.self, kind: .credential)
    }

    /// IDs of credentials whose secret values are present in the Keychain on this Mac.
    func storedSecretIDs() throws -> Set<UUID> {
        Set(try keychain.accounts(kind: .secret).compactMap(UUID.init(uuidString:)))
    }

    /// The secret values for a credential, or `nil` if they aren't in the Keychain.
    func values(for credentialID: UUID) throws -> CredentialValues? {
        guard let data = try keychain.data(kind: .secret, account: credentialID.uuidString) else { return nil }
        return try JSONDecoder().decode(CredentialValues.self, from: data)
    }

    // MARK: Writing

    func save(_ project: Project) throws {
        try write(project, kind: .project, account: project.id, label: "Agent Secrets project: \(project.name)")
    }

    func deleteProject(_ id: UUID) throws {
        try keychain.delete(kind: .project, account: id.uuidString)
    }

    func save(_ service: Service) throws {
        try write(service, kind: .service, account: service.id, label: "Agent Secrets service: \(service.name)")
    }

    func deleteService(_ id: UUID) throws {
        try keychain.delete(kind: .service, account: id.uuidString)
    }

    /// Saves metadata, and values when given. Values are written first so a failure can't leave
    /// freshly registered metadata without its secret.
    func save(_ credential: Credential, values: CredentialValues?, serviceName: String) throws {
        let label = "Agent Secrets: \(serviceName) – \(credential.name)"
        if let values {
            try write(values, kind: .secret, account: credential.id, label: label)
        }
        try write(credential, kind: .credential, account: credential.id, label: label + " (metadata)")
    }

    func deleteCredential(_ id: UUID) throws {
        try keychain.delete(kind: .secret, account: id.uuidString)
        try keychain.delete(kind: .credential, account: id.uuidString)
    }

    // MARK: Helpers

    private func write<T: Encodable>(_ value: T, kind: Keychain.Kind, account: UUID, label: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try keychain.set(encoder.encode(value), kind: kind, account: account.uuidString, label: label)
    }

    private func decodeAll<T: Decodable>(_ type: T.Type, kind: Keychain.Kind) throws -> [T] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Skip items that fail to decode rather than hiding everything else.
        return try keychain.allData(kind: kind).values.compactMap { try? decoder.decode(T.self, from: $0) }
    }
}
