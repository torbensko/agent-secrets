import SwiftUI
import UniformTypeIdentifiers

/// Inline editing of a new or existing credential, laid out like the detail view it replaces.
struct CredentialEditView: View {
    @Binding var draft: CredentialDraft

    @Environment(AppModel.self) private var model
    @State private var newProjectName = ""
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    private var icons: IconCache { .shared }

    private var previewIcon: Data? {
        if case .existing(let service) = draft.source, let icon = service.iconPNG { return icon }
        return icons.icon(for: draft.iconDomain)
    }

    private var validationMessage: String? { model.validationMessage(for: draft) }

    var body: some View {
        Form {
            Section {
                header
            } footer: {
                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(.secondary)
                }
            }

            if draft.source == .custom {
                Section {
                    FieldRow(label: "Service") {
                        TextField("Service", text: $draft.serviceName, prompt: Text("e.g. Render"))
                            .textFieldStyle(.plain)
                            .labelsHidden()
                    }
                    FieldRow(label: "Website") {
                        TextField("Website", text: $draft.website, prompt: Text("Optional, e.g. render.com"))
                            .textFieldStyle(.plain)
                            .labelsHidden()
                    }
                }
            }

            Section {
                ForEach($draft.fields) { $field in
                    EditableFieldRow(field: $field) {
                        draft.fields.removeAll { $0.id == field.id }
                    }
                }
                Button {
                    draft.fields.append(EditableField(definition: FieldDefinition(name: "", kind: .secret), value: ""))
                } label: {
                    Label {
                        Text("add field")
                    } icon: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                    }
                }
                .buttonStyle(.borderless)
            } footer: {
                if draft.fields.contains(where: { $0.definition.kind == .multiline }) {
                    Text("Drop a file, such as a .p8 key, onto a multi-line field to fill it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                FieldRow(label: "Projects") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.projects) { project in
                            Toggle(project.name, isOn: Binding(
                                get: { draft.projectIDs.contains(project.id) },
                                set: { isOn in
                                    if isOn { draft.projectIDs.insert(project.id) } else { draft.projectIDs.remove(project.id) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                        HStack {
                            TextField("New Project", text: $newProjectName, prompt: Text("New project…"))
                                .textFieldStyle(.plain)
                                .labelsHidden()
                                .onSubmit(addProject)
                            if !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty {
                                Button("Add", action: addProject)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                FieldRow(label: "Expires") {
                    HStack {
                        Toggle("Expires", isOn: $draft.hasExpiry)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        if draft.hasExpiry {
                            DatePicker("Expiry Date", selection: $draft.expiry, displayedComponents: .date)
                                .labelsHidden()
                                .fixedSize()
                        } else {
                            Text("Never").foregroundStyle(.secondary)
                        }
                    }
                }
                FieldRow(label: "Notes") {
                    TextField("Notes", text: $draft.notes, prompt: Text("Shown to agents. Don’t put secrets here."), axis: .vertical)
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .lineLimit(1...8)
                }
            }

            if !draft.isNew {
                Section {
                    Button("Delete Credential…", role: .destructive) { confirmDelete = true }
                        .foregroundStyle(.red)
                        .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Cancel") {
                    endFieldEditing()
                    model.cancelEditing()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    // Commit the focused field first so a value still being typed is saved.
                    endFieldEditing()
                    model.saveEditing()
                }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(validationMessage != nil)
            }
        }
        .confirmationDialog("Delete “\(draft.trimmedName)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = draft.credentialID, let credential = model.credentials.first(where: { $0.id == id }) {
                    endFieldEditing()
                    model.cancelEditing()
                    model.delete(credential)
                }
            }
        } message: {
            Text("This removes it from the Keychain on all your Macs. Agents will no longer be able to read it.")
        }
        .task(id: draft.iconDomain) {
            guard let domain = draft.iconDomain else { return }
            // Debounce while a website is being typed.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await icons.load(domain)
        }
        .onAppear {
            if draft.isNew { nameFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ServiceIcon(name: draft.serviceDisplayName.isEmpty ? "?" : draft.serviceDisplayName, iconPNG: previewIcon, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name", text: $draft.name, prompt: Text("Credential name"))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .labelsHidden()
                    .focused($nameFocused)
                Text(draft.serviceDisplayName.isEmpty ? "New service" : draft.serviceDisplayName)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func addProject() {
        if let project = model.createProject(named: newProjectName) {
            draft.projectIDs.insert(project.id)
            newProjectName = ""
        }
    }

    private func endFieldEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

/// One editable field: a removal control, the label above the value, and a type menu, as in Contacts.
private struct EditableFieldRow: View {
    @Binding var field: EditableField
    var onRemove: () -> Void

    @State private var isRevealed = false
    @State private var isImporting = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove field")
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    TextField("Label", text: $field.definition.name, prompt: Text("label"))
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelsHidden()
                        .fixedSize()
                    Menu {
                        Picker("Type", selection: $field.definition.kind) {
                            ForEach(FieldDefinition.Kind.allCases, id: \.self) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(field.definition.kind.title)
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Field type")
                }
                valueEditor
            }
        }
        .padding(.vertical, 2)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            return load(url)
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { _ = load(url) }
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch field.definition.kind {
        case .text:
            TextField("Value", text: $field.value, prompt: Text("value"))
                .textFieldStyle(.plain)
                .labelsHidden()
        case .secret:
            HStack(spacing: 6) {
                Group {
                    if isRevealed {
                        TextField("Value", text: $field.value, prompt: Text("secret"))
                    } else {
                        SecureField("Value", text: $field.value, prompt: Text("secret"))
                    }
                }
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .labelsHidden()
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(isRevealed ? "Hide" : "Show")
            }
        case .multiline:
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $field.value)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 70, maxHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if field.value.isEmpty {
                            Text("Paste or drop a file")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isDropTargeted ? 2 : 1)
                    )
                Button("Choose File…") { isImporting = true }
                    .controlSize(.small)
            }
        }
    }

    private func load(_ url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        field.value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if field.definition.kind != .multiline, field.value.contains("\n") { field.definition.kind = .multiline }
        return true
    }
}
