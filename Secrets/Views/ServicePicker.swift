import SwiftUI

/// The first step of adding a credential: pick a preset, one of your services, or a custom service.
struct ServicePicker: View {
    let projectID: UUID?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let domain: String?
        let iconPNG: Data?
        let choice: ServiceChoice
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Services you've added that aren't presets.
    private var yourServices: [Item] {
        model.services.values
            .filter { $0.templateID == nil }
            .filter { trimmedQuery.isEmpty || $0.name.localizedStandardContains(trimmedQuery) || ($0.domain?.localizedStandardContains(trimmedQuery) ?? false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { Item(id: $0.id.uuidString, title: $0.name, subtitle: $0.domain, domain: $0.domain, iconPNG: $0.iconPNG, choice: .existing($0)) }
    }

    private var presets: [Item] {
        ServiceTemplate.all
            .filter { trimmedQuery.isEmpty || $0.matches(search: trimmedQuery) }
            .map { template in
                let saved = model.services[template.serviceID]
                return Item(
                    id: template.id, title: template.name, subtitle: template.defaultCredentialName,
                    domain: template.domain, iconPNG: saved?.iconPNG, choice: .template(template)
                )
            }
    }

    /// A tile for whatever was typed, when it isn't already an exact match.
    private var customItem: Item? {
        guard !trimmedQuery.isEmpty else { return nil }
        let domain = ServiceInput.domain(from: trimmedQuery)
        let name = domain.map(ServiceInput.displayName(forDomain:)) ?? trimmedQuery
        let exactMatch = (presets + yourServices).contains {
            $0.title.caseInsensitiveCompare(name) == .orderedSame || (domain != nil && $0.domain == domain)
        }
        guard !exactMatch else { return nil }
        return Item(id: "custom-query", title: name, subtitle: domain ?? "New service", domain: domain, iconPNG: nil, choice: .custom(name: name, domain: domain))
    }

    private var allItems: [Item] {
        [customItem].compactMap { $0 } + yourServices + presets
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Text("What would you like to add?")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $query, prompt: Text("Search services or paste a URL"))
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($searchFocused)
                        .onSubmit { if let first = allItems.first { choose(first.choice) } }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let customItem {
                        grid([customItem])
                    }
                    if !yourServices.isEmpty {
                        section("Your Services", items: yourServices)
                    }
                    if !presets.isEmpty {
                        section("Presets", items: presets)
                    }
                    if trimmedQuery.isEmpty {
                        section("Other", items: [
                            Item(id: "custom", title: "Custom", subtitle: "Any other service", domain: nil, iconPNG: nil, choice: .custom(name: "", domain: nil)),
                        ])
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            Divider()
            HStack {
                Text("Tip: paste a website address to fetch the service’s icon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 640, height: 560)
        .onAppear { searchFocused = true }
    }

    private func section(_ title: String, items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            grid(items)
        }
    }

    private func grid(_ items: [Item]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items) { item in
                ServiceTile(title: item.title, subtitle: item.subtitle, domain: item.domain, iconPNG: item.iconPNG, isCustom: item.id == "custom") {
                    choose(item.choice)
                }
            }
        }
    }

    private func choose(_ choice: ServiceChoice) {
        dismiss()
        model.beginNewCredential(choice, projectID: projectID)
    }
}

private struct ServiceTile: View {
    let title: String
    let subtitle: String?
    let domain: String?
    let iconPNG: Data?
    let isCustom: Bool
    let action: () -> Void

    @State private var isHovered = false
    private var icons: IconCache { .shared }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isCustom {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ServiceIcon(name: title, iconPNG: iconPNG ?? icons.icon(for: domain), size: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHovered ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .task(id: domain) {
            if iconPNG == nil, let domain { await icons.load(domain) }
        }
    }
}
