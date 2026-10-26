import Foundation
import Observation

/// Site icons by domain, kept in memory and in the Caches folder so presets don't refetch each time.
@Observable
@MainActor
final class IconCache {
    static let shared = IconCache()

    private(set) var icons: [String: Data] = [:]
    @ObservationIgnored private var attempted: Set<String> = []

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appending(path: "com.torbensko.secrets/icons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    func icon(for domain: String?) -> Data? {
        domain.flatMap { icons[$0] }
    }

    func load(_ domain: String) async {
        guard !attempted.contains(domain) else { return }
        attempted.insert(domain)
        let file = directory.appending(path: "\(domain).png")
        if let data = try? Data(contentsOf: file) {
            icons[domain] = data
            return
        }
        guard let data = await IconFetcher.fetchIcon(domain: domain) else { return }
        icons[domain] = data
        try? data.write(to: file, options: .atomic)
    }
}
