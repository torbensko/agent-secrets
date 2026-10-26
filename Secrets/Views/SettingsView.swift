import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AgentsSettings()
                .tabItem { Label("Agents", systemImage: "terminal") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "key.icloud") }
        }
        .frame(width: 560)
    }
}

private struct AgentsSettings: View {
    private var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/Secrets.app/Contents/MacOS/Secrets"
    }

    private var claudeCommand: String {
        "claude mcp add --scope user secrets -- '\(executablePath)' --mcp"
    }

    private var jsonConfig: String {
        """
        {
          "mcpServers": {
            "secrets": {
              "command": "\(executablePath)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section {
                CopyableCode(text: claudeCommand)
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Adds Secrets for every project. Each session only sees the credentials of the authorised folder it starts in.")
            }

            Section {
                CopyableCode(text: jsonConfig)
            } header: {
                Text("Other Agents")
            } footer: {
                Text("For tools configured with a JSON file. The server uses stdio and must be launched from the project folder.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }
}

private struct StorageSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Credentials") {
                    if model.keychainMode == .iCloud {
                        Label("iCloud Keychain", systemImage: "icloud")
                    } else {
                        Label("This Mac Only", systemImage: "laptopcomputer")
                    }
                }
            } header: {
                Text("Keychain")
            } footer: {
                if model.keychainMode == .iCloud {
                    Text("Credentials, services and projects sync to your other Macs through iCloud Keychain when it’s turned on. Authorised folders and activity stay on this Mac.")
                } else {
                    Text("This build isn’t signed with the Keychain entitlement, so credentials are stored in the login keychain and don’t sync.")
                }
            }

            Section {
                LabeledContent("Folders & Activity") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                    }
                }
            } footer: {
                Text("Stored in \(AppPaths.supportDirectory.path.abbreviatingHome). These files never contain secret values.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }
}

private struct CopyableCode: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Pasteboard.copy(text, concealed: false)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}
