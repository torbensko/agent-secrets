import Foundation

/// What the owner picked on the "What would you like to add?" screen.
enum ServiceChoice {
    case template(ServiceTemplate)
    case existing(Service)
    case custom(name: String, domain: String?)
}

struct EditableField: Identifiable, Hashable {
    var definition: FieldDefinition
    var value: String
    var id: UUID { definition.id }
}

/// An in-progress edit of a new or existing credential, shown inline in the detail pane.
struct CredentialDraft {
    enum ServiceSource: Equatable {
        case existing(Service)
        case template(ServiceTemplate)
        /// A new service described by `serviceName` and `website`.
        case custom
    }

    var credentialID: UUID?
    var source: ServiceSource
    var serviceName = ""
    var website = ""
    var name = ""
    var fields: [EditableField] = []
    var projectIDs: Set<UUID> = []
    var hasExpiry = false
    var expiry = Calendar.current.date(byAdding: .day, value: 90, to: .now) ?? .now
    var notes = ""

    var isNew: Bool { credentialID == nil }

    var customDomain: String? { ServiceInput.domain(from: website) }

    var serviceDisplayName: String {
        switch source {
        case .existing(let service): service.name
        case .template(let template): template.name
        case .custom: serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The domain whose icon should be fetched, when the service doesn't have one stored yet.
    var iconDomain: String? {
        switch source {
        case .existing: nil
        case .template(let template): template.domain
        case .custom: customDomain
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
