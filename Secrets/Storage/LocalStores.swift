import Foundation

enum AppPaths {
    /// `~/Library/Application Support/com.torbensko.secrets`. Holds per-machine data only; no secrets.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appending(path: "com.torbensko.secrets", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static let markerFileName = ".secrets-project"
}

/// The per-machine registry of authorised folders.
struct FolderRegistry: Sendable {
    let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "folders.json")) {
        self.fileURL = fileURL
    }

    func load() -> [FolderGrant] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([FolderGrant].self, from: data)) ?? []
    }

    func save(_ grants: [FolderGrant]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(grants).write(to: fileURL, options: .atomic)
    }
}

/// An append-only JSON Lines log of MCP access, shared by the app and the MCP server process.
struct ActivityLog: Sendable {
    let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "activity.jsonl")) {
        self.fileURL = fileURL
    }

    func append(_ entry: ActivityEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        // O_APPEND keeps concurrent writers from several agent sessions from interleaving lines.
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    /// The most recent entries, oldest first.
    func load(limit: Int = 5000) -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n"))
            .suffix(limit)
            .compactMap { try? decoder.decode(ActivityEntry.self, from: Data($0)) }
    }

    func modificationDate() -> Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func clear() throws {
        try Data().write(to: fileURL, options: .atomic)
    }
}

/// Works out which authorised folder, if any, contains a directory.
enum AccessResolver {
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The most specific grant whose folder is the directory or one of its ancestors.
    static func grant(for directory: String, in grants: [FolderGrant]) -> FolderGrant? {
        let directory = normalize(directory)
        return grants
            .map { (grant: $0, path: normalize($0.path)) }
            .filter { candidate in
                let prefix = candidate.path.hasSuffix("/") ? candidate.path : candidate.path + "/"
                return directory == candidate.path || directory.hasPrefix(prefix)
            }
            .max { $0.path.count < $1.path.count }?
            .grant
    }
}
