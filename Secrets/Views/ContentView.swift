import SwiftUI

enum SidebarItem: Hashable {
    case all
    case attention
    case project(UUID)
    case folders
    case activity
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .all
    @State private var newProjectName = ""
    @State private var renamingProject: Project?
    @State private var renameText = ""
    @State private var deletingProject: Project?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            detail
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newCredential(let projectID):
                ServicePicker(projectID: projectID)
            case .grantFolder(let url, let projectID):
                GrantFolderSheet(url: url, initialProjectID: projectID)
            }
        }
        .alert("New Project", isPresented: $model.isCreatingProject) {
            TextField("Name", text: $newProjectName)
            Button("Create") {
                if let project = model.createProject(named: newProjectName) {
                    selection = .project(project.id)
                }
                newProjectName = ""
            }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        } message: {
            Text("Credentials tagged with this project are available to agents working in its authorised folders.")
        }
        .alert("Rename Project", isPresented: isPresent($renamingProject)) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renamingProject { model.rename(renamingProject, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deletingProject?.name ?? "")”?",
            isPresented: isPresent($deletingProject),
            presenting: deletingProject
        ) { project in
            Button("Delete Project", role: .destructive) {
                if selection == .project(project.id) { selection = .all }
                model.delete(project)
            }
        } message: { project in
            let folders = model.grants(for: project.id).count
            Text("Its credentials are kept but untagged. \(folders == 1 ? "1 authorised folder" : "\(folders) authorised folders") will lose access.")
        }
        .alert("Something Went Wrong", isPresented: isPresent($model.errorMessage)) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.editing != nil) { _, isEditing in
            // Editing happens in the credentials pane, so bring it forward.
            if isEditing, selection == .folders || selection == .activity || selection == nil {
                selection = .all
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Picks up changes synced from other Macs and edits made by other processes.
            model.reload()
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Credentials") {
                Label("All Credentials", systemImage: "key")
                    .badge(model.credentials.count)
                    .tag(SidebarItem.all)
                let attention = model.credentials(matching: .attention).count
                Label("Needs Attention", systemImage: "exclamationmark.triangle")
                    .badge(attention)
                    .tag(SidebarItem.attention)
            }

            Section("Projects") {
                ForEach(model.projects) { project in
                    Label(project.name, systemImage: "folder")
                        .badge(model.credentials(matching: .project(project.id)).count)
                        .tag(SidebarItem.project(project.id))
                        .contextMenu {
                            Button("Rename…") {
                                renameText = project.name
                                renamingProject = project
                            }
                            Button("Grant Folder Access…") {
                                if let url = FolderPicker.choose() { model.sheet = .grantFolder(url, projectID: project.id) }
                            }
                            Divider()
                            Button("Delete…", role: .destructive) { deletingProject = project }
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let url = urls.first(where: \.hasDirectoryPath) else { return false }
                            model.sheet = .grantFolder(url, projectID: project.id)
                            return true
                        }
                }
            }

            Section("Access") {
                Label("Folders", systemImage: "folder.badge.person.crop")
                    .badge(model.grants.count)
                    .tag(SidebarItem.folders)
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.activity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    model.isCreatingProject = true
                } label: {
                    Label("New Project", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .all {
        case .all:
            CredentialsBrowser(filter: .all).id(SidebarItem.all)
        case .attention:
            CredentialsBrowser(filter: .attention).id(SidebarItem.attention)
        case .project(let id):
            CredentialsBrowser(filter: .project(id)).id(SidebarItem.project(id))
        case .folders:
            FoldersView()
        case .activity:
            ActivityView()
        }
    }
}

/// A Bool binding that's true while an optional has a value, and clears it when set to false.
@MainActor
func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(
        get: { value.wrappedValue != nil },
        set: { if !$0 { value.wrappedValue = nil } }
    )
}
