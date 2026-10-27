import SwiftUI

/// A list of credentials grouped by service, with the selected credential's details alongside.
struct CredentialsBrowser: View {
    let filter: CredentialFilter

    @Environment(AppModel.self) private var model
    @State private var selectedID: Credential.ID?
    @State private var searchText = ""
    @State private var pendingDelete: Credential?

    private struct ServiceGroup: Identifiable {
        let service: Service?
        let credentials: [Credential]
        var id: UUID? { service?.id }
    }

    private var visibleCredentials: [Credential] {
        let credentials = model.credentials(matching: filter)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return credentials }
        return credentials.filter { credential in
            credential.name.localizedStandardContains(query)
                || (model.service(for: credential)?.name.localizedStandardContains(query) ?? false)
                || credential.notes.localizedStandardContains(query)
        }
    }

    private var groups: [ServiceGroup] {
        Dictionary(grouping: visibleCredentials, by: \.serviceID)
            .map { serviceID, credentials in
                ServiceGroup(
                    service: model.services[serviceID],
                    credentials: credentials.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                )
            }
            .sorted { ($0.service?.name ?? "").localizedStandardCompare($1.service?.name ?? "") == .orderedAscending }
    }

    private var selected: Credential? {
        model.credentials.first { $0.id == selectedID }
    }

    private var projectID: UUID? {
        if case .project(let id) = filter { id } else { nil }
    }

    private var title: String {
        switch filter {
        case .all: "All Credentials"
        case .attention: "Needs Attention"
        case .project(let id): model.project(id)?.name ?? "Project"
        }
    }

    var body: some View {
        @Bindable var model = model
        HSplitView {
            list
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
            Group {
                if let current = model.editing {
                    // A focused field commits after Save or Cancel clears the draft, so ignore late writes
                    // rather than force-unwrapping a draft that no longer exists.
                    CredentialEditView(draft: Binding(
                        get: { model.editing ?? current },
                        set: { if model.editing != nil { model.editing = $0 } }
                    ))
                } else if let selected {
                    CredentialDetailView(credential: selected)
                        .id(selected.id)
                } else {
                    ContentUnavailableView("No Credential Selected", systemImage: "key")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Credential", systemImage: "plus") {
                    model.sheet = .newCredential(projectID: projectID)
                }
                .help("Add a credential")
                .disabled(model.editing != nil)
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: isPresent($pendingDelete),
            presenting: pendingDelete
        ) { credential in
            Button("Delete", role: .destructive) {
                if selectedID == credential.id { selectedID = nil }
                model.delete(credential)
            }
        } message: { _ in
            Text("This removes it from the Keychain on all your Macs. Agents will no longer be able to read it.")
        }
        .onAppear {
            if selectedID == nil { selectedID = groups.first?.credentials.first?.id }
        }
        .onChange(of: model.revealCredentialID, initial: true) { _, id in
            guard let id else { return }
            selectedID = id
            model.revealCredentialID = nil
        }
    }

    private var subtitle: String {
        let count = model.credentials(matching: filter).count
        return count == 1 ? "1 credential" : "\(count) credentials"
    }

    private var list: some View {
        List(selection: $selectedID) {
            if let projectID {
                ProjectFoldersSection(projectID: projectID)
            }
            ForEach(groups) { group in
                Section(group.service?.name ?? "Unknown Service") {
                    ForEach(group.credentials) { credential in
                        CredentialRow(credential: credential)
                            .tag(credential.id)
                            .contextMenu { contextMenu(for: credential) }
                    }
                }
            }
        }
        .overlay {
            if visibleCredentials.isEmpty {
                emptyState
            }
        }
        .onDeleteCommand {
            pendingDelete = selected
        }
        // Like 1Password, the list is locked while an item is being edited.
        .disabled(model.editing != nil)
    }

    @ViewBuilder
    private func contextMenu(for credential: Credential) -> some View {
        Button("Edit") { model.beginEditing(credential) }
        if model.isAvailable(credential), !credential.fields.isEmpty {
            Menu("Copy") {
                ForEach(credential.fields) { field in
                    Button(field.name) {
                        if let value = model.values(for: credential)?[field] { Pasteboard.copy(value, concealed: field.isSecret) }
                    }
                }
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = credential }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            switch filter {
            case .all:
                ContentUnavailableView {
                    Label("No Credentials", systemImage: "key")
                } description: {
                    Text("Add credentials for the dev services your agents use.")
                } actions: {
                    Button("New Credential") { model.sheet = .newCredential(projectID: nil) }
                }
            case .attention:
                ContentUnavailableView(
                    "Nothing Needs Attention",
                    systemImage: "checkmark.seal",
                    description: Text("Missing and expiring credentials appear here.")
                )
            case .project:
                ContentUnavailableView {
                    Label("No Credentials", systemImage: "key")
                } description: {
                    Text("Credentials tagged with this project are available to agents in its authorised folders.")
                } actions: {
                    Button("New Credential") { model.sheet = .newCredential(projectID: projectID) }
                }
            }
        }
    }
}

private struct ProjectFoldersSection: View {
    let projectID: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Authorised Folders") {
            let grants = model.grants(for: projectID)
            ForEach(grants) { grant in
                Label {
                    Text(grant.path.abbreviatingHome)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(grant.path)
                } icon: {
                    Image(systemName: "folder")
                }
                .foregroundStyle(.secondary)
                .selectionDisabled()
            }
            Button {
                if let url = FolderPicker.choose() { model.sheet = .grantFolder(url, projectID: projectID) }
            } label: {
                Label(grants.isEmpty ? "Grant Folder Access…" : "Add Folder…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .selectionDisabled()
        }
    }
}

private struct CredentialRow: View {
    let credential: Credential
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            ServiceIcon(service: model.service(for: credential), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.name)
                    .lineLimit(1)
                Text(projectsText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            CredentialStatusIcon(credential: credential)
        }
        .padding(.vertical, 2)
    }

    private var projectsText: String {
        let names = model.projectNames(for: credential)
        return names.isEmpty ? "No projects" : names.joined(separator: ", ")
    }
}

struct CredentialStatusIcon: View {
    let credential: Credential
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.isAvailable(credential) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help("Not in the Keychain on this Mac")
        } else {
            switch credential.expiryStatus() {
            case .expired:
                Image(systemName: "clock.badge.xmark.fill")
                    .foregroundStyle(.red)
                    .help("Expired")
            case .soon:
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .foregroundStyle(.orange)
                    .help("Expires soon")
            case .none, .valid:
                EmptyView()
            }
        }
    }
}

extension String {
    var abbreviatingHome: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}

enum Pasteboard {
    static func copy(_ string: String, concealed: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        if concealed {
            // Asks clipboard managers not to record the value.
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }
}
