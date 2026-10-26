import SwiftUI

/// A label above its value, as in 1Password and Contacts. Shared by viewing and editing so the
/// layout stays put when switching between them.
struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

struct CredentialDetailView: View {
    let credential: Credential

    @Environment(AppModel.self) private var model
    @State private var values: CredentialValues?
    @State private var revealed: Set<FieldDefinition.ID> = []

    private var service: Service? { model.service(for: credential) }
    private var isAvailable: Bool { model.isAvailable(credential) }

    var body: some View {
        Form {
            Section {
                header
            }

            if !isAvailable {
                Section {
                    missingNotice
                }
            }

            Section {
                if credential.fields.isEmpty {
                    Text("No fields").foregroundStyle(.secondary)
                }
                ForEach(credential.fields) { field in
                    fieldRow(field)
                }
            }

            Section {
                let projects = model.projects.filter { credential.projectIDs.contains($0.id) }
                FieldRow(label: "Projects") {
                    if projects.isEmpty {
                        Text("None, so no agent can read it")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            ForEach(projects) { project in
                                ProjectTag(name: project.name)
                            }
                        }
                    }
                }
                if let expiresAt = credential.expiresAt {
                    FieldRow(label: "Expires") {
                        HStack(spacing: 6) {
                            Text(expiresAt, format: .dateTime.day().month(.wide).year())
                            Text("(\(expiresAt, format: .relative(presentation: .named)))")
                                .foregroundStyle(expiryColor)
                        }
                    }
                }
                if !credential.notes.isEmpty {
                    FieldRow(label: "Notes") {
                        Text(credential.notes)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                LabeledContent("Created", value: credential.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Modified", value: credential.updatedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Stored In", value: model.keychainMode == .iCloud ? "iCloud Keychain" : "Keychain on this Mac")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { model.beginEditing(credential) }
                    .help("Edit this credential")
            }
        }
        .task(id: credential) {
            values = isAvailable ? model.values(for: credential) : nil
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ServiceIcon(service: service, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(credential.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text(service?.name ?? "")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            CredentialStatusIcon(credential: credential)
                .font(.title2)
        }
        .padding(.vertical, 4)
    }

    private var missingNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Not in the Keychain on This Mac")
                    .fontWeight(.semibold)
                Text("This credential is registered but its value is missing. It may have been deleted on another Mac, or iCloud Keychain hasn't synced yet. Agents get an error until you re-enter it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Re-enter…") { model.beginEditing(credential) }
        }
    }

    private func fieldRow(_ field: FieldDefinition) -> some View {
        let value = values?[field]
        let isShown = !field.isSecret || revealed.contains(field.id)
        return HStack(alignment: .center, spacing: 8) {
            FieldRow(label: field.name) {
                if value == nil || value?.isEmpty == true {
                    Text(isAvailable ? "Empty" : "Missing").foregroundStyle(.tertiary)
                } else if isShown {
                    Text(value ?? "")
                        .font(field.kind == .multiline ? .system(.caption, design: .monospaced) : .body.monospaced())
                        .lineLimit(field.kind == .multiline ? 8 : 3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(String(repeating: "•", count: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if let value, !value.isEmpty {
                if field.isSecret {
                    Button {
                        if revealed.contains(field.id) { revealed.remove(field.id) } else { revealed.insert(field.id) }
                    } label: {
                        Image(systemName: isShown ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(isShown ? "Hide" : "Show")
                }
                Button {
                    Pasteboard.copy(value, concealed: field.isSecret)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy \(field.name)")
            }
        }
    }

    private var expiryColor: Color {
        switch credential.expiryStatus() {
        case .expired: .red
        case .soon: .orange
        case .none, .valid: .secondary
        }
    }
}

private struct ProjectTag: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "folder.fill")
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}
