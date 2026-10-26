import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var confirmClear = false
    @State private var selection = Set<ActivityEntry.ID>()

    private var entries: [ActivityEntry] {
        let newestFirst = model.activity.reversed()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(newestFirst) }
        return newestFirst.filter { entry in
            [entry.tool, entry.folder, entry.project, entry.service, entry.credential, entry.outcome.title]
                .compactMap { $0 }
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        Group {
            if model.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Each time an agent lists or reads credentials, it appears here. Secret values are never logged.")
                )
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                table
            }
        }
        .navigationTitle("Activity")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear Log", systemImage: "trash") { confirmClear = true }
                    .disabled(model.activity.isEmpty)
                    .help("Clear the activity log")
            }
        }
        .confirmationDialog("Clear the activity log?", isPresented: $confirmClear) {
            Button("Clear Log", role: .destructive) { model.clearActivity() }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("Time") { entry in
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                    .monospacedDigit()
            }
            .width(min: 120, ideal: 140)

            TableColumn("Result") { entry in
                OutcomeLabel(outcome: entry.outcome)
                    .help(entry.detail ?? entry.outcome.title)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Tool") { entry in
                Text(entry.tool).font(.body.monospaced())
            }
            .width(min: 90, ideal: 120)

            TableColumn("Project") { entry in
                Text(entry.project ?? "—").foregroundStyle(entry.project == nil ? .secondary : .primary)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Credential") { entry in
                if let service = entry.service {
                    Text([service, entry.credential].compactMap { $0 }.joined(separator: " › "))
                } else {
                    Text(entry.detail ?? "—").foregroundStyle(.secondary)
                }
            }
            .width(min: 120, ideal: 200)

            TableColumn("Folder") { entry in
                Text(entry.folder.abbreviatingHome)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(entry.folder)
            }
            .width(min: 140, ideal: 240)
        }
    }
}

private struct OutcomeLabel: View {
    let outcome: ActivityEntry.Outcome

    var body: some View {
        Label {
            Text(outcome.title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch outcome {
        case .granted: "checkmark.circle.fill"
        case .denied: "hand.raised.fill"
        case .notFound: "questionmark.circle.fill"
        case .missing: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch outcome {
        case .granted: .green
        case .denied: .red
        case .notFound: .secondary
        case .missing, .failed: .orange
        }
    }
}
