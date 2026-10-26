import Foundation

/// A minimal MCP server over stdio (newline-delimited JSON-RPC 2.0).
///
/// It runs inside the app's own executable (`Secrets --mcp`) so it shares the app's code signature and
/// therefore its Keychain access. Each session is bound to the authorised folder containing its working
/// directory. Bindings, metadata and the registry are re-read on every call, so revoking a folder or
/// untagging a credential takes effect immediately.
final class MCPServer {
    static let name = "agent-secrets"
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let vault: Vault
    private let registry: FolderRegistry
    private let log: ActivityLog
    private let workingDirectory: String

    init(vault: Vault, registry: FolderRegistry, log: ActivityLog, workingDirectory: String) {
        self.vault = vault
        self.registry = registry
        self.log = log
        self.workingDirectory = workingDirectory
    }

    static func runUntilEndOfInput() {
        let server = MCPServer(
            vault: Vault(keychain: .detect()),
            registry: FolderRegistry(),
            log: ActivityLog(),
            workingDirectory: FileManager.default.currentDirectoryPath
        )
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = server.handle(line) {
                FileHandle.standardOutput.write(response + "\n")
            }
        }
    }

    // MARK: JSON-RPC

    /// Handles one message and returns the response line, or `nil` for notifications.
    func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]) }

        // Notifications have no id; responses from the client have no method. Neither needs a reply.
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        let result: [String: Any]
        switch method {
        case "initialize":
            result = initialize(params)
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools]
        case "tools/call":
            result = callTool(params)
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String ?? ""
        let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": Self.name, "title": "Agent Secrets", "version": appVersion],
            "instructions": """
                Provides development credentials (API tokens, keys) for the project this folder belongs to. \
                Call list_credentials to see what's available, then get_credential to read values. \
                Never print secret values in output, commit them, or write them into files in the repository.
                """,
        ]
    }

    private func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Tools

    static var tools: [[String: Any]] { [
        [
            "name": "list_credentials",
            "title": "List Credentials",
            "description": "Lists the credentials available to this project: service, name, field names, expiry and whether the value is present on this Mac. Never returns secret values.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "get_credential",
            "title": "Get Credential",
            "description": "Returns the field values of a credential available to this project.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "service": ["type": "string", "description": "Service name or domain, e.g. \"Cloudflare\" or \"cloudflare.com\"."],
                    "name": ["type": "string", "description": "Credential name, e.g. \"API Token\". Optional when the service has only one credential in this project."],
                ],
                "required": ["service"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "whoami",
            "title": "Who Am I",
            "description": "Returns the project and authorised folder this session is bound to. Use it to debug access.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
    ] }

    struct ToolError: Error {
        var message: String
        var outcome: ActivityEntry.Outcome
        var service: String?
        var credential: String?
    }

    private struct Binding {
        let grant: FolderGrant
        let project: Project
    }

    private func callTool(_ params: [String: Any]) -> [String: Any] {
        let tool = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        var binding: Binding?
        do {
            binding = try bind()
            let payload: [String: Any]
            switch tool {
            case "list_credentials":
                payload = try listCredentials(binding!)
            case "get_credential":
                payload = try getCredential(binding!, arguments: arguments)
            case "whoami":
                payload = whoami(binding!)
                record(tool: tool, binding: binding, outcome: .granted)
            default:
                throw ToolError(message: "Unknown tool '\(tool)'. Available: list_credentials, get_credential, whoami.", outcome: .failed)
            }
            return ["content": [["type": "text", "text": encode(payload)]], "structuredContent": payload, "isError": false]
        } catch let error as ToolError {
            if tool == "whoami", error.outcome == .denied {
                // whoami is how agents debug access, so report the unbound state as data, not an error.
                let payload = whoamiUnbound(reason: error.message)
                record(tool: tool, binding: nil, outcome: .denied)
                return ["content": [["type": "text", "text": encode(payload)]], "structuredContent": payload, "isError": false]
            }
            record(tool: tool, binding: binding, outcome: error.outcome, service: error.service, credential: error.credential, detail: error.message)
            return ["content": [["type": "text", "text": error.message]], "isError": true]
        } catch {
            record(tool: tool, binding: binding, outcome: .failed, detail: error.localizedDescription)
            return ["content": [["type": "text", "text": "Agent Secrets couldn't read the Keychain: \(error.localizedDescription)"]], "isError": true]
        }
    }

    private func bind() throws -> Binding {
        guard let grant = AccessResolver.grant(for: workingDirectory, in: registry.load()) else {
            throw ToolError(
                message: "The folder '\(workingDirectory)' isn't authorised to use any credentials. Ask the owner to open Agent Secrets and grant this folder (or a parent folder) access to a project under Folders.",
                outcome: .denied
            )
        }
        guard let project = try vault.projects().first(where: { $0.id == grant.projectID }) else {
            throw ToolError(
                message: "The folder '\(grant.path)' is authorised for a project that no longer exists. Ask the owner to reassign it in Agent Secrets.",
                outcome: .denied
            )
        }
        return Binding(grant: grant, project: project)
    }

    private func credentials(in project: Project) throws -> [(credential: Credential, service: Service?)] {
        let services = Dictionary(uniqueKeysWithValues: try vault.services().map { ($0.id, $0) })
        return try vault.credentials()
            .filter { $0.projectIDs.contains(project.id) }
            .map { ($0, services[$0.serviceID]) }
            .sorted { ($0.service?.name ?? "", $0.credential.name) < ($1.service?.name ?? "", $1.credential.name) }
    }

    private func listCredentials(_ binding: Binding) throws -> [String: Any] {
        let stored = try vault.storedSecretIDs()
        let items: [[String: Any]] = try credentials(in: binding.project).map { credential, service in
            var item: [String: Any] = [
                "service": service?.name ?? "Unknown",
                "name": credential.name,
                "fields": credential.fields.map { ["name": $0.name, "secret": $0.isSecret] },
                "availability": stored.contains(credential.id) ? "available" : "missing",
            ]
            if let domain = service?.domain { item["domain"] = domain }
            if let expiresAt = credential.expiresAt {
                item["expiresAt"] = expiresAt.formatted(.iso8601)
                item["expired"] = credential.expiryStatus() == .expired
            }
            if !credential.notes.isEmpty { item["notes"] = credential.notes }
            return item
        }
        record(tool: "list_credentials", binding: binding, outcome: .granted, detail: "\(items.count) credentials")
        return ["project": binding.project.name, "credentials": items]
    }

    private func getCredential(_ binding: Binding, arguments: [String: Any]) throws -> [String: Any] {
        let serviceQuery = (arguments["service"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let nameQuery = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = try credentials(in: binding.project)
        let summary = available.isEmpty
            ? "none"
            : available.map { "\($0.service?.name ?? "Unknown") / \($0.credential.name)" }.joined(separator: ", ")

        guard !serviceQuery.isEmpty else {
            throw ToolError(message: "Missing 'service' argument. Available in project '\(binding.project.name)': \(summary).", outcome: .notFound)
        }
        let queryDomain = ServiceInput.domain(from: serviceQuery)
        let inService = available.filter { _, service in
            guard let service else { return false }
            if service.name.caseInsensitiveCompare(serviceQuery) == .orderedSame { return true }
            guard let queryDomain, let domain = service.domain else { return false }
            return queryDomain == domain || queryDomain.hasSuffix("." + domain)
        }
        guard !inService.isEmpty else {
            throw ToolError(
                message: "No service '\(serviceQuery)' in project '\(binding.project.name)'. Available: \(summary).",
                outcome: .notFound, service: serviceQuery, credential: nameQuery
            )
        }
        let serviceName = inService[0].service?.name ?? serviceQuery

        let match: Credential
        if let nameQuery, !nameQuery.isEmpty {
            guard let found = inService.first(where: { $0.credential.name.caseInsensitiveCompare(nameQuery) == .orderedSame }) else {
                throw ToolError(
                    message: "No credential '\(nameQuery)' for service '\(serviceName)' in project '\(binding.project.name)'. Available for \(serviceName): \(inService.map(\.credential.name).joined(separator: ", ")).",
                    outcome: .notFound, service: serviceName, credential: nameQuery
                )
            }
            match = found.credential
        } else if inService.count == 1 {
            match = inService[0].credential
        } else {
            throw ToolError(
                message: "Service '\(serviceName)' has several credentials in project '\(binding.project.name)'. Pass 'name', one of: \(inService.map(\.credential.name).joined(separator: ", ")).",
                outcome: .notFound, service: serviceName
            )
        }

        guard let values = try vault.values(for: match.id) else {
            throw ToolError(
                message: "'\(match.name)' for \(serviceName) is registered but not present in the Keychain on this Mac. Ask the owner to re-enter it in Agent Secrets.",
                outcome: .missing, service: serviceName, credential: match.name
            )
        }

        var fields: [String: String] = [:]
        for field in match.fields {
            fields[field.name] = values[field] ?? ""
        }
        var payload: [String: Any] = ["service": serviceName, "name": match.name, "fields": fields]
        if let expiresAt = match.expiresAt {
            payload["expiresAt"] = expiresAt.formatted(.iso8601)
            if match.expiryStatus() == .expired {
                payload["warning"] = "This credential expired on \(expiresAt.formatted(date: .long, time: .omitted)) and may no longer work."
            }
        }
        record(tool: "get_credential", binding: binding, outcome: .granted, service: serviceName, credential: match.name)
        return payload
    }

    private func whoami(_ binding: Binding) -> [String: Any] {
        [
            "bound": true,
            "project": binding.project.name,
            "authorisedFolder": binding.grant.path,
            "workingDirectory": workingDirectory,
            "keychain": vault.keychain.mode == .iCloud ? "iCloud Keychain" : "local keychain (sync unavailable)",
        ]
    }

    private func whoamiUnbound(reason: String) -> [String: Any] {
        ["bound": false, "workingDirectory": workingDirectory, "reason": reason]
    }

    private func record(
        tool: String,
        binding: Binding?,
        outcome: ActivityEntry.Outcome,
        service: String? = nil,
        credential: String? = nil,
        detail: String? = nil
    ) {
        log.append(ActivityEntry(
            tool: tool,
            folder: binding?.grant.path ?? workingDirectory,
            project: binding?.project.name,
            service: service,
            credential: credential,
            outcome: outcome,
            detail: detail
        ))
    }
}

private extension FileHandle {
    func write(_ string: String) {
        write(Data(string.utf8))
    }
}
