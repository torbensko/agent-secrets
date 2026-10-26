import SwiftUI

struct FoldersView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<FolderGrant.ID>()
    @State private var pendingRevoke = Set<FolderGrant.ID>()
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if model.grants.isEmpty {
                ContentUnavailableView {
                    Label("No Authorised Folders", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Agents only get credentials when they run inside a folder you’ve granted to a project. Drag a project folder here, or choose one.")
                } actions: {
                    Button("Grant Folder Access…", action: chooseFolder)
                }
            } else {
                table
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.hasDirectoryPath) else { return false }
            model.sheet = .grantFolder(url, projectID: nil)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle("Folders")
        .navigationSubtitle(model.grants.count == 1 ? "1 authorised folder" : "\(model.grants.count) authorised folders")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Revoke Access", systemImage: "minus") { pendingRevoke = selection }
                    .disabled(selection.isEmpty)
                    .help("Revoke access for the selected folders")
                Button("Grant Folder Access", systemImage: "plus", action: chooseFolder)
                    .help("Grant a folder access to a project")
            }
        }
        .confirmationDialog(
            pendingRevoke.count == 1 ? "Revoke access for this folder?" : "Revoke access for \(pendingRevoke.count) folders?",
            isPresented: Binding(get: { !pendingRevoke.isEmpty }, set: { if !$0 { pendingRevoke = [] } })
        ) {
            Button("Revoke Access", role: .destructive) {
                model.revoke(pendingRevoke)
                selection.subtract(pendingRevoke)
                pendingRevoke = []
            }
        } message: {
            Text("Agents running there will lose access immediately.")
        }
    }

    private var table: some View {
        Table(model.grants, selection: $selection) {
            TableColumn("Folder") { grant in
                let exists = FileManager.default.fileExists(atPath: grant.path)
                Label {
                    Text(grant.path.abbreviatingHome)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(exists ? .primary : .secondary)
                        .help(exists ? grant.path : "\(grant.path) (folder not found)")
                } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: grant.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
            }
            .width(min: 220, ideal: 360)

            TableColumn("Project") { grant in
                Picker("Project", selection: Binding(
                    get: { grant.projectID },
                    set: { model.reassign(grant.id, to: $0) }
                )) {
                    if model.project(grant.projectID) == nil {
                        Text("Deleted Project").tag(grant.projectID)
                    }
                    ForEach(model.projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                .labelsHidden()
            }
            .width(min: 120, ideal: 170)

            TableColumn("Last Access") { grant in
                if let date = model.lastAccess(for: grant) {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("Never").foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 120)

            TableColumn("Added") { grant in
                Text(grant.addedAt, format: .dateTime.day().month().year())
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: FolderGrant.ID.self) { ids in
            Button("Show in Finder") { reveal(ids) }
            Divider()
            Button("Revoke Access…", role: .destructive) { pendingRevoke = ids }
        } primaryAction: { ids in
            reveal(ids)
        }
        .onDeleteCommand { pendingRevoke = selection }
    }

    private func chooseFolder() {
        if let url = FolderPicker.choose() {
            model.sheet = .grantFolder(url, projectID: nil)
        }
    }

    private func reveal(_ ids: Set<FolderGrant.ID>) {
        let urls = model.grants.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

struct GrantFolderSheet: View {
    let url: URL
    let initialProjectID: UUID?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var newProjectName = ""
    @State private var writeMarker = false

    private var path: String { AccessResolver.normalize(url.path) }
    private var existingGrant: FolderGrant? { model.grants.first { $0.path == path } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.headline)
                            Text(path.abbreviatingHome)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                } footer: {
                    if let existingGrant, let project = model.project(existingGrant.projectID) {
                        Text("This folder is already authorised for “\(project.name)”. Granting it again changes its project.")
                    }
                }

                Section {
                    if model.projects.isEmpty {
                        TextField("Project Name", text: $newProjectName, prompt: Text("e.g. Accelerate"))
                    } else {
                        Picker("Project", selection: $projectID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(model.projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                    }
                } header: {
                    Text("Project")
                } footer: {
                    Text("Agents running in this folder or any folder inside it get this project’s credentials.")
                }

                Section {
                    Toggle("Add a marker file", isOn: $writeMarker)
                } footer: {
                    Text("Writes \(AppPaths.markerFileName) containing only the project name, so you can tell the folder is authorised. It never contains secrets.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Grant Access", action: grant)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canGrant)
            }
            .padding()
        }
        .frame(width: 480, height: 420)
        .onAppear {
            projectID = initialProjectID ?? existingGrant?.projectID ?? (model.projects.count == 1 ? model.projects.first?.id : nil)
            writeMarker = existingGrant?.wroteMarker ?? false
        }
    }

    private var canGrant: Bool {
        model.projects.isEmpty ? !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty : projectID != nil
    }

    private func grant() {
        let target = model.projects.isEmpty ? model.createProject(named: newProjectName)?.id : projectID
        guard let target else { return }
        model.grant(url, to: target, writeMarker: writeMarker)
        dismiss()
    }
}
