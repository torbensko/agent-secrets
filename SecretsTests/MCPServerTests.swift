import Foundation
import Testing
@testable import Secrets

/// Exercises the MCP server against the real Keychain, using a throwaway service prefix and temp files.
@Suite(.serialized)
final class MCPServerTests {
    let vault = Vault(keychain: .detect(servicePrefix: "com.torbensko.secrets.tests.\(UUID().uuidString)"))
    let directory = FileManager.default.temporaryDirectory.appending(path: "secrets-tests-\(UUID().uuidString)")
    let registry: FolderRegistry
    let log: ActivityLog
    let project = Project(name: "Accelerate")
    let service = Service(id: ServiceTemplate.cloudflare.serviceID, name: "Cloudflare", domain: "cloudflare.com", templateID: "cloudflare")
    let field = FieldDefinition(name: "API Token", kind: .secret)
    let credential: Credential
    let projectFolder: URL

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registry = FolderRegistry(fileURL: directory.appending(path: "folders.json"))
        log = ActivityLog(fileURL: directory.appending(path: "activity.jsonl"))
        projectFolder = directory.appending(path: "accelerate")
        try FileManager.default.createDirectory(at: projectFolder.appending(path: "apps/web"), withIntermediateDirectories: true)
        credential = Credential(
            id: UUID(), serviceID: service.id, name: "API Token", fields: [field], projectIDs: [project.id],
            notes: "Zone edit for accelerate.dev", expiresAt: nil, createdAt: .now, updatedAt: .now
        )

        var values = CredentialValues()
        values[field] = "cf-secret-123"
        try vault.save(project)
        try vault.save(service)
        try vault.save(credential, values: values, serviceName: service.name)
    }

    deinit {
        try? vault.deleteCredential(credential.id)
        try? vault.deleteService(service.id)
        try? vault.deleteProject(project.id)
        try? FileManager.default.removeItem(at: directory)
    }

    private func server() -> MCPServer {
        MCPServer(vault: vault, registry: registry, log: log, workingDirectory: projectFolder.appending(path: "apps/web").path)
    }

    private func grantProjectFolder() throws {
        try registry.save([FolderGrant(id: UUID(), path: projectFolder.path, projectID: project.id, addedAt: .now, wroteMarker: false)])
    }

    /// Calls a tool and returns (isError, text).
    private func call(_ tool: String, _ arguments: [String: Any] = [:]) throws -> (Bool, String) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try #require(server().handle(line))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return (result["isError"] as? Bool ?? false, content.first?["text"] as? String ?? "")
    }

    @Test func initializeAndListTools() throws {
        let initialize = try #require(server().handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        #expect(initialize.contains(#""protocolVersion":"2025-06-18""#))
        #expect(server().handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let tools = try #require(server().handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(tools.contains("get_credential") && tools.contains("list_credentials") && tools.contains("whoami"))
    }

    @Test func unauthorisedFolderGetsNothing() throws {
        let (isError, text) = try call("get_credential", ["service": "Cloudflare"])
        #expect(isError)
        #expect(text.contains("isn't authorised"))
        #expect(!text.contains("cf-secret-123"))
        let (whoamiError, whoami) = try call("whoami")
        #expect(!whoamiError)
        #expect(whoami.contains(#""bound":false"#))
    }

    @Test func authorisedFolderReadsCredential() throws {
        try grantProjectFolder()

        let (listError, list) = try call("list_credentials")
        #expect(!listError)
        #expect(list.contains(#""availability":"available""#))
        #expect(list.contains("Zone edit for accelerate.dev"))
        #expect(!list.contains("cf-secret-123"))

        let (getError, value) = try call("get_credential", ["service": "dash.cloudflare.com"])
        #expect(!getError)
        #expect(value.contains(#""API Token":"cf-secret-123""#))

        let (wrongNameError, wrongName) = try call("get_credential", ["service": "Cloudflare", "name": "Global Key"])
        #expect(wrongNameError)
        #expect(wrongName.contains("Available for Cloudflare: API Token"))

        let logged = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(!logged.contains("cf-secret-123"))
        #expect(log.load().contains { $0.tool == "get_credential" && $0.outcome == .granted && $0.project == "Accelerate" })
    }

    @Test func untaggedCredentialIsNotReachable() throws {
        try grantProjectFolder()
        var untagged = credential
        untagged.projectIDs = []
        try vault.save(untagged, values: nil, serviceName: service.name)

        let (isError, text) = try call("get_credential", ["service": "Cloudflare"])
        #expect(isError)
        #expect(text.contains("No service 'Cloudflare' in project 'Accelerate'"))
    }

    @Test func missingValueFailsWithSpecificError() throws {
        try grantProjectFolder()
        try vault.keychain.delete(kind: .secret, account: credential.id.uuidString)

        let (_, list) = try call("list_credentials")
        #expect(list.contains(#""availability":"missing""#))
        let (isError, text) = try call("get_credential", ["service": "Cloudflare", "name": "api token"])
        #expect(isError)
        #expect(text.contains("registered but not present in the Keychain on this Mac"))
    }
}
