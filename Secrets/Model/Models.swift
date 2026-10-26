import Foundation

/// A project defined in the app. Credentials are tagged with projects, and folders are granted to them.
struct Project: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// A dev service such as Cloudflare. Holds presentation details shared by its credentials.
struct Service: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var domain: String?
    var iconPNG: Data?
    /// Set when the service was created from a built-in template.
    var templateID: String?
}

struct FieldDefinition: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case text
        case secret
        case multiline

        var title: String {
            switch self {
            case .text: "Text"
            case .secret: "Secret"
            case .multiline: "Multi-line Secret"
            }
        }
    }

    var id: UUID
    var name: String
    var kind: Kind

    init(id: UUID = UUID(), name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    var isSecret: Bool { kind != .text }
}

/// Credential metadata. Never contains secret values; those live in a separate Keychain item.
struct Credential: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var serviceID: UUID
    var name: String
    var fields: [FieldDefinition]
    var projectIDs: Set<UUID>
    var notes: String
    var expiresAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

/// Secret values for a credential, keyed by field ID.
struct CredentialValues: Codable, Hashable, Sendable {
    var values: [String: String] = [:]

    subscript(field: FieldDefinition) -> String? {
        get { values[field.id.uuidString] }
        set { values[field.id.uuidString] = newValue }
    }
}

enum ExpiryStatus: Sendable {
    case none, valid, soon, expired

    var needsAttention: Bool { self == .soon || self == .expired }
}

extension Credential {
    static let expiryWarningInterval: TimeInterval = 14 * 24 * 60 * 60

    func expiryStatus(now: Date = .now) -> ExpiryStatus {
        guard let expiresAt else { return .none }
        if expiresAt <= now { return .expired }
        if expiresAt.timeIntervalSince(now) < Self.expiryWarningInterval { return .soon }
        return .valid
    }
}

/// Maps an absolute folder path on this Mac to a project. Not synced.
struct FolderGrant: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var path: String
    var projectID: UUID
    var addedAt: Date
    var wroteMarker: Bool
}

struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case granted, denied, notFound, missing, failed

        var title: String {
            switch self {
            case .granted: "Granted"
            case .denied: "Denied"
            case .notFound: "Not Found"
            case .missing: "Missing"
            case .failed: "Failed"
            }
        }
    }

    var id: UUID = UUID()
    var date: Date = .now
    var tool: String
    /// The authorised folder the session was bound to, or the working directory when unbound.
    var folder: String
    var project: String?
    var service: String?
    var credential: String?
    var outcome: Outcome
    var detail: String?
}
