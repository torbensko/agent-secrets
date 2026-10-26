import AppKit
import Observation

enum ActiveSheet: Identifiable {
    case newCredential(projectID: UUID?)
    case grantFolder(URL, projectID: UUID?)

    var id: String {
        switch self {
        case .newCredential: "new"
        case .grantFolder(let url, _): "grant-\(url.path)"
        }
    }
}

enum CredentialFilter: Hashable {
    case all
    case attention
    case project(UUID)
}

@Observable
@MainActor
final class AppModel {
    let vault: Vault
    let registry: FolderRegistry
    let log: ActivityLog

    private(set) var projects: [Project] = []
    private(set) var services: [UUID: Service] = [:]
    private(set) var credentials: [Credential] = []
    private(set) var storedSecretIDs: Set<UUID> = []
    private(set) var grants: [FolderGrant] = []
    private(set) var activity: [ActivityEntry] = []

    var sheet: ActiveSheet?
    /// The credential being added or edited inline, if any.
    var editing: CredentialDraft?
    /// Set after saving so the list can select the saved credential.
    var revealCredentialID: UUID?
    var isCreatingProject = false
    var errorMessage: String?

    @ObservationIgnored private var activityModified: Date?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(vault: Vault = Vault(keychain: .detect()), registry: FolderRegistry = FolderRegistry(), log: ActivityLog = ActivityLog()) {
        self.vault = vault
        self.registry = registry
        self.log = log
        reload()
        pollTask = Task { [weak self] in
            // The MCP server runs in other processes; pick up their log entries.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.reloadActivityIfChanged()
            }
        }
    }

    var keychainMode: Keychain.Mode { vault.keychain.mode }

    func reload() {
        do {
            projects = try vault.projects()
            services = Dictionary(try vault.services().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            credentials = try vault.credentials()
            storedSecretIDs = try vault.storedSecretIDs()
        } catch {
            report(error)
        }
        grants = registry.load().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        reloadActivityIfChanged(force: true)
    }

    private func reloadActivityIfChanged(force: Bool = false) {
        let modified = log.modificationDate()
        guard force || modified != activityModified else { return }
        activityModified = modified
        activity = log.load()
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    // MARK: Queries

    func service(for credential: Credential) -> Service? {
        services[credential.serviceID]
    }

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    func isAvailable(_ credential: Credential) -> Bool {
        storedSecretIDs.contains(credential.id)
    }

    func needsAttention(_ credential: Credential) -> Bool {
        !isAvailable(credential) || credential.expiryStatus().needsAttention
    }

    func credentials(matching filter: CredentialFilter) -> [Credential] {
        switch filter {
        case .all: credentials
        case .attention: credentials.filter(needsAttention)
        case .project(let id): credentials.filter { $0.projectIDs.contains(id) }
        }
    }

    func projectNames(for credential: Credential) -> [String] {
        projects.filter { credential.projectIDs.contains($0.id) }.map(\.name)
    }

    func grants(for projectID: UUID) -> [FolderGrant] {
        grants.filter { $0.projectID == projectID }
    }

    func lastAccess(for grant: FolderGrant) -> Date? {
        activity.last { $0.folder == grant.path && $0.outcome != .denied }?.date
    }

    /// Default fields for a new credential in an existing service: the template's, else those of the
    /// service's most recent credential, so repeated generic entries keep the same shape.
    func defaultFields(for service: Service) -> [FieldDefinition] {
        if let template = ServiceTemplate.all.first(where: { $0.id == service.templateID }) {
            return template.makeFields()
        }
        let latest = credentials.filter { $0.serviceID == service.id }.max { $0.updatedAt < $1.updatedAt }
        if let latest { return latest.fields.map { FieldDefinition(name: $0.name, kind: $0.kind) } }
        return ServiceTemplate.genericFields.map { FieldDefinition(name: $0.name, kind: $0.kind) }
    }

    func values(for credential: Credential) -> CredentialValues? {
        do {
            return try vault.values(for: credential.id)
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: Projects

    @discardableResult
    func createProject(named name: String) -> Project? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let project = Project(name: name)
        do {
            try vault.save(project)
            reload()
            return project
        } catch {
            report(error)
            return nil
        }
    }

    func rename(_ project: Project, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != project.name else { return }
        var renamed = project
        renamed.name = name
        perform { try vault.save(renamed) }
    }

    /// Deletes a project, untags its credentials and revokes its folders.
    func delete(_ project: Project) {
        perform {
            for var credential in credentials where credential.projectIDs.contains(project.id) {
                credential.projectIDs.remove(project.id)
                try vault.save(credential, values: nil, serviceName: service(for: credential)?.name ?? "")
            }
            try revoke(grants(for: project.id).map(\.id), reloading: false)
            try vault.deleteProject(project.id)
        }
    }

    // MARK: Credentials

    /// Saves a credential and its values, creating its service first when it's new.
    func save(_ credential: Credential, values: CredentialValues, newService: Service?) -> Bool {
        do {
            if let newService { try vault.save(newService) }
            let serviceName = newService?.name ?? service(for: credential)?.name ?? ""
            try vault.save(credential, values: values, serviceName: serviceName)
            reload()
            return true
        } catch {
            report(error)
            reload()
            return false
        }
    }

    func delete(_ credential: Credential) {
        perform {
            try vault.deleteCredential(credential.id)
            // Drop the service once nothing uses it, so it doesn't linger in suggestions.
            if !credentials.contains(where: { $0.serviceID == credential.serviceID && $0.id != credential.id }) {
                try vault.deleteService(credential.serviceID)
            }
        }
    }

    // MARK: Editing

    func beginNewCredential(_ choice: ServiceChoice, projectID: UUID?) {
        var draft = CredentialDraft(credentialID: nil, source: .custom)
        if let projectID { draft.projectIDs = [projectID] }
        var definitions = ServiceTemplate.genericFields.map { FieldDefinition(name: $0.name, kind: $0.kind) }
        switch choice {
        case .template(let template):
            if let saved = services[template.serviceID] {
                draft.source = .existing(saved)
                definitions = defaultFields(for: saved)
            } else {
                draft.source = .template(template)
                definitions = template.makeFields()
            }
            draft.name = template.defaultCredentialName
        case .existing(let service):
            draft.source = .existing(service)
            definitions = defaultFields(for: service)
        case .custom(let name, let domain):
            draft.serviceName = name
            draft.website = domain ?? ""
        }
        draft.fields = definitions.map { EditableField(definition: $0, value: "") }
        if let serviceID = serviceID(for: draft), !draft.name.isEmpty {
            draft.name = uniqueName(draft.name, in: serviceID)
        }
        editing = draft
    }

    func beginEditing(_ credential: Credential) {
        guard let service = service(for: credential) else { return }
        var draft = CredentialDraft(credentialID: credential.id, source: .existing(service))
        draft.name = credential.name
        draft.projectIDs = credential.projectIDs
        draft.notes = credential.notes
        if let expiresAt = credential.expiresAt {
            draft.hasExpiry = true
            draft.expiry = expiresAt
        }
        let values = isAvailable(credential) ? self.values(for: credential) : nil
        draft.fields = credential.fields.map { EditableField(definition: $0, value: values?[$0] ?? "") }
        editing = draft
    }

    func cancelEditing() {
        editing = nil
    }

    /// Why the draft can't be saved yet, or `nil` when it can.
    func validationMessage(for draft: CredentialDraft) -> String? {
        if draft.serviceDisplayName.isEmpty { return "Enter a service name." }
        if draft.trimmedName.isEmpty { return "Enter a name for this credential." }
        if let serviceID = serviceID(for: draft), credentials.contains(where: {
            $0.serviceID == serviceID && $0.id != draft.credentialID
                && $0.name.caseInsensitiveCompare(draft.trimmedName) == .orderedSame
        }) {
            return "\(draft.serviceDisplayName) already has a credential named “\(draft.trimmedName)”."
        }
        let names = draft.fields.map { $0.definition.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.isEmpty { return "Add at least one field." }
        if names.contains(where: \.isEmpty) { return "Every field needs a label." }
        if Set(names).count != names.count { return "Field labels must be unique." }
        return nil
    }

    @discardableResult
    func saveEditing() -> Bool {
        guard let draft = editing, validationMessage(for: draft) == nil else { return false }

        let service: Service
        var newService: Service?
        switch draft.source {
        case .existing(let existing):
            service = existing
        case .template(let template):
            service = Service(
                id: template.serviceID, name: template.name, domain: template.domain,
                iconPNG: IconCache.shared.icon(for: template.domain), templateID: template.id
            )
            newService = service
        case .custom:
            if let existing = serviceID(for: draft).flatMap({ services[$0] }) {
                service = existing
            } else {
                service = Service(
                    id: UUID(), name: draft.serviceDisplayName, domain: draft.customDomain,
                    iconPNG: IconCache.shared.icon(for: draft.customDomain), templateID: nil
                )
                newService = service
            }
        }

        let definitions = draft.fields.map {
            FieldDefinition(id: $0.definition.id, name: $0.definition.name.trimmingCharacters(in: .whitespaces), kind: $0.definition.kind)
        }
        var values = CredentialValues()
        for (definition, field) in zip(definitions, draft.fields) {
            values[definition] = field.value
        }

        var credential = draft.credentialID.flatMap { id in credentials.first { $0.id == id } } ?? Credential(
            id: UUID(), serviceID: service.id, name: "", fields: [], projectIDs: [], notes: "",
            expiresAt: nil, createdAt: .now, updatedAt: .now
        )
        credential.name = draft.trimmedName
        credential.fields = definitions
        credential.projectIDs = draft.projectIDs
        credential.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        credential.expiresAt = draft.hasExpiry ? Calendar.current.startOfDay(for: draft.expiry) : nil
        credential.updatedAt = .now

        guard save(credential, values: values, newService: newService) else { return false }
        editing = nil
        revealCredentialID = credential.id
        return true
    }

    /// The stored service a draft will be saved into, if it already exists.
    private func serviceID(for draft: CredentialDraft) -> UUID? {
        switch draft.source {
        case .existing(let service):
            return service.id
        case .template(let template):
            return template.serviceID
        case .custom:
            let name = draft.serviceDisplayName
            let domain = draft.customDomain
            return services.values.first {
                (!name.isEmpty && $0.name.caseInsensitiveCompare(name) == .orderedSame) || (domain != nil && $0.domain == domain)
            }?.id
        }
    }

    private func uniqueName(_ name: String, in serviceID: UUID) -> String {
        let taken = Set(credentials.filter { $0.serviceID == serviceID }.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    // MARK: Folders

    func grant(_ url: URL, to projectID: UUID, writeMarker: Bool) {
        let path = AccessResolver.normalize(url.path)
        var all = registry.load()
        var grant = all.first { $0.path == path }
            ?? FolderGrant(id: UUID(), path: path, projectID: projectID, addedAt: .now, wroteMarker: false)
        grant.projectID = projectID
        if writeMarker, let project = project(projectID) {
            do {
                try project.name.write(to: markerURL(for: grant), atomically: true, encoding: .utf8)
                grant.wroteMarker = true
            } catch {
                report(error)
            }
        }
        all.removeAll { $0.id == grant.id }
        all.append(grant)
        perform { try registry.save(all) }
    }

    func reassign(_ grantID: FolderGrant.ID, to projectID: UUID) {
        var all = registry.load()
        guard let index = all.firstIndex(where: { $0.id == grantID }) else { return }
        all[index].projectID = projectID
        if all[index].wroteMarker, let project = project(projectID) {
            try? project.name.write(to: markerURL(for: all[index]), atomically: true, encoding: .utf8)
        }
        perform { try registry.save(all) }
    }

    func revoke(_ grantIDs: some Collection<FolderGrant.ID>) {
        perform { try revoke(Array(grantIDs), reloading: false) }
    }

    private func revoke(_ grantIDs: [FolderGrant.ID], reloading: Bool) throws {
        var all = registry.load()
        for grant in all where grantIDs.contains(grant.id) && grant.wroteMarker {
            try? FileManager.default.removeItem(at: markerURL(for: grant))
        }
        all.removeAll { grantIDs.contains($0.id) }
        try registry.save(all)
        if reloading { reload() }
    }

    private func markerURL(for grant: FolderGrant) -> URL {
        URL(fileURLWithPath: grant.path).appending(path: AppPaths.markerFileName)
    }

    // MARK: Activity

    func clearActivity() {
        perform { try log.clear() }
    }

    // MARK: Helpers

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            report(error)
        }
        reload()
    }
}
