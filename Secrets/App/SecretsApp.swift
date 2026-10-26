import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        // Agents launch this same executable as an MCP server, so it shares the app's Keychain access.
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.runUntilEndOfInput()
        } else {
            SecretsApp.main()
        }
    }
}

struct SecretsApp: App {
    @State private var model = AppModel()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        Window("Secrets", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            UpdateCommands(updates: updates)
            CommandGroup(replacing: .newItem) {
                Button("New Credential…") { model.sheet = .newCredential(projectID: nil) }
                    .keyboardShortcut("n")
                Button("New Project…") { model.isCreatingProject = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Grant Folder Access…") {
                    if let url = FolderPicker.choose() { model.sheet = .grantFolder(url, projectID: nil) }
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.reload() }
                    .keyboardShortcut("r")
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum FolderPicker {
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        panel.message = "Choose a project folder. Agents running inside it will get the credentials of the project you assign."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
