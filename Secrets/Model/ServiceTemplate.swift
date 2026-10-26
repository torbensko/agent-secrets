import Foundation

/// A built-in service with a known field schema, offered as a preset when adding a credential.
struct ServiceTemplate: Identifiable, Hashable, Sendable {
    let id: String
    /// Fixed so the same service created on two Macs merges into one item via iCloud Keychain.
    let serviceID: UUID
    let name: String
    let domain: String
    /// Extra search terms, e.g. "claude" for Anthropic.
    let keywords: [String]
    let defaultCredentialName: String
    let fields: [Field]

    struct Field: Hashable, Sendable {
        let name: String
        let kind: FieldDefinition.Kind
    }

    func makeFields() -> [FieldDefinition] {
        fields.map { FieldDefinition(name: $0.name, kind: $0.kind) }
    }

    func matches(domain other: String) -> Bool {
        other == domain || other.hasSuffix("." + domain)
    }

    func matches(search query: String) -> Bool {
        name.localizedStandardContains(query)
            || domain.localizedStandardContains(query)
            || keywords.contains { $0.localizedStandardContains(query) }
    }

    private init(
        id: String, serviceID: String, name: String, domain: String, keywords: [String] = [],
        credentialName: String, fields: [(String, FieldDefinition.Kind)]
    ) {
        self.id = id
        self.serviceID = UUID(uuidString: serviceID)!
        self.name = name
        self.domain = domain
        self.keywords = keywords
        self.defaultCredentialName = credentialName
        self.fields = fields.map { Field(name: $0.0, kind: $0.1) }
    }

    static let cloudflare = ServiceTemplate(
        id: "cloudflare", serviceID: "5C0F1A2E-0000-4000-8000-00000000C1F1",
        name: "Cloudflare", domain: "cloudflare.com", keywords: ["workers", "wrangler", "pages"],
        credentialName: "API Token", fields: [("API Token", .secret), ("Account ID", .text)]
    )

    static let appStoreConnect = ServiceTemplate(
        id: "app-store-connect", serviceID: "5C0F1A2E-0000-4000-8000-0000000A5C01",
        name: "App Store Connect", domain: "appstoreconnect.apple.com", keywords: ["apple", "testflight", "ios"],
        credentialName: "API Key", fields: [("Key ID", .text), ("Issuer ID", .text), ("Private Key", .multiline)]
    )

    static let anthropic = ServiceTemplate(
        id: "anthropic", serviceID: "5C0F1A2E-0000-4000-8000-0000000A7C01",
        name: "Anthropic", domain: "anthropic.com", keywords: ["claude"],
        credentialName: "API Key", fields: [("API Key", .secret)]
    )

    static let openAI = ServiceTemplate(
        id: "openai", serviceID: "5C0F1A2E-0000-4000-8000-00000000A101",
        name: "OpenAI", domain: "openai.com", keywords: ["gpt", "chatgpt"],
        credentialName: "API Key", fields: [("API Key", .secret)]
    )

    static let gitHub = ServiceTemplate(
        id: "github", serviceID: "5C0F1A2E-0000-4000-8000-0000000061C1",
        name: "GitHub", domain: "github.com", keywords: ["git"],
        credentialName: "Personal Access Token", fields: [("Token", .secret)]
    )

    static let aws = ServiceTemplate(
        id: "aws", serviceID: "5C0F1A2E-0000-4000-8000-000000000A35",
        name: "AWS", domain: "aws.amazon.com", keywords: ["amazon", "s3", "cloudfront", "lambda"],
        credentialName: "Access Key",
        fields: [("Access Key ID", .text), ("Secret Access Key", .secret), ("Region", .text)]
    )

    static let googleCloud = ServiceTemplate(
        id: "google-cloud", serviceID: "5C0F1A2E-0000-4000-8000-0000000006C9",
        name: "Google Cloud", domain: "cloud.google.com", keywords: ["gcp", "firebase", "gemini"],
        credentialName: "Service Account", fields: [("Service Account JSON", .multiline)]
    )

    static let stripe = ServiceTemplate(
        id: "stripe", serviceID: "5C0F1A2E-0000-4000-8000-00000005791E",
        name: "Stripe", domain: "stripe.com", keywords: ["payments"],
        credentialName: "Secret Key", fields: [("Secret Key", .secret), ("Publishable Key", .text)]
    )

    static let vercel = ServiceTemplate(
        id: "vercel", serviceID: "5C0F1A2E-0000-4000-8000-0000000FE5CE",
        name: "Vercel", domain: "vercel.com", keywords: ["next"],
        credentialName: "Access Token", fields: [("Token", .secret)]
    )

    static let supabase = ServiceTemplate(
        id: "supabase", serviceID: "5C0F1A2E-0000-4000-8000-0000005BA5E0",
        name: "Supabase", domain: "supabase.com", keywords: ["postgres", "database"],
        credentialName: "Project Keys",
        fields: [("Project URL", .text), ("Anon Key", .secret), ("Service Role Key", .secret)]
    )

    static let sentry = ServiceTemplate(
        id: "sentry", serviceID: "5C0F1A2E-0000-4000-8000-00000005E717",
        name: "Sentry", domain: "sentry.io", keywords: ["errors", "crash"],
        credentialName: "Auth Token", fields: [("Auth Token", .secret)]
    )

    static let all: [ServiceTemplate] = [
        anthropic, appStoreConnect, aws, cloudflare, gitHub, googleCloud, openAI, sentry, stripe, supabase, vercel,
    ]

    /// Fields for services without a template.
    static let genericFields: [Field] = [Field(name: "Value", kind: .secret)]

    static func match(name: String, domain: String?) -> ServiceTemplate? {
        all.first { template in
            template.name.caseInsensitiveCompare(name) == .orderedSame
                || domain.map(template.matches(domain:)) == true
        }
    }
}

/// Interprets what the owner types into the service field: a name or a URL.
enum ServiceInput {
    /// Returns the host for input that looks like a URL or domain, without a leading `www.`.
    static func domain(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("."), !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let host = URLComponents(string: withScheme)?.host?.lowercased(),
              host.contains("."),
              host.split(separator: ".").allSatisfy({ !$0.isEmpty })
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A readable name for a domain, e.g. `dash.cloudflare.com` → `Cloudflare`.
    static func displayName(forDomain domain: String) -> String {
        var labels = domain.split(separator: ".").map(String.init)
        guard labels.count > 1 else { return domain.capitalized }
        labels.removeLast()
        // Second-level country domains such as co.uk or com.au.
        if labels.count > 1, let last = labels.last, ["co", "com", "net", "org", "ac", "gov"].contains(last) {
            labels.removeLast()
        }
        let label = labels.last ?? domain
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}
