import Foundation

struct ConnectionProfile: Codable, Equatable {
    // The original profile retains the existing trusted key and SSH alias.
    static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id = UUID()
    var name: String
    var host = "office.example.com"
    var port = 22
    var username = NSUserName()

    var hostKeyAlias: String { id == Self.legacyID ? "office-proxy-pc" : "office-proxy-\(id.uuidString)" }
    var knownHostsFilename: String { id == Self.legacyID ? "office_known_hosts" : "office_known_hosts-\(id.uuidString)" }
}

struct Settings: Codable, Equatable {
    var profiles: [ConnectionProfile]
    var selectedProfileID: UUID
    var domains: [String]
    var home: String

    var selectedIndex: Int { profiles.firstIndex { $0.id == selectedProfileID } ?? 0 }
    var selectedProfile: ConnectionProfile { profiles[selectedIndex] }
    var host: String {
        get { selectedProfile.host }
        set { profiles[selectedIndex].host = newValue }
    }
    var port: Int {
        get { selectedProfile.port }
        set { profiles[selectedIndex].port = newValue }
    }
    var username: String {
        get { selectedProfile.username }
        set { profiles[selectedIndex].username = newValue }
    }

    init() {
        let profile = ConnectionProfile(id: ConnectionProfile.legacyID, name: "Office")
        profiles = [profile]; selectedProfileID = profile.id
        domains = ["intranet.example.com"]; home = "https://intranet.example.com/"
    }

    enum CodingKeys: String, CodingKey {
        case profiles, selectedProfileID, domains, home, host, port, username
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        domains = try values.decodeIfPresent([String].self, forKey: .domains) ?? domains
        home = try values.decodeIfPresent(String.self, forKey: .home) ?? home
        if let saved = try values.decodeIfPresent([ConnectionProfile].self, forKey: .profiles), !saved.isEmpty {
            profiles = saved
            let selected = try values.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
            selectedProfileID = saved.first(where: { $0.id == selected })?.id ?? saved[0].id
        } else {
            host = try values.decodeIfPresent(String.self, forKey: .host) ?? host
            port = try values.decodeIfPresent(Int.self, forKey: .port) ?? port
            username = try values.decodeIfPresent(String.self, forKey: .username) ?? username
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(profiles, forKey: .profiles)
        try values.encode(selectedProfileID, forKey: .selectedProfileID)
        try values.encode(domains, forKey: .domains)
        try values.encode(home, forKey: .home)
    }
}

struct SettingsSnapshot: Codable {
    var savedAt: Date
    var settings: Settings
}

/// Keep the previous on-disk value before every change, including profile deletion.
struct SettingsStore {
    let directory: URL
    var historyLimit = 50
    var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    var historyURL: URL { directory.appendingPathComponent("settings-history.json") }

    func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return Settings() }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
    }

    func history() throws -> [SettingsSnapshot] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        return try JSONDecoder().decode([SettingsSnapshot].self, from: Data(contentsOf: historyURL))
    }

    func save(_ updated: Settings) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: settingsURL.path) {
            let previous = try load()
            if previous == updated { return }
            var snapshots = try history()
            let attributes = try manager.attributesOfItem(atPath: settingsURL.path)
            let date = attributes[.modificationDate] as? Date ?? Date()
            snapshots.insert(SettingsSnapshot(savedAt: date, settings: previous), at: 0)
            // A failed backup must never overwrite the user's current settings.
            try write(Array(snapshots.prefix(historyLimit)), to: historyURL)
        }
        try write(updated, to: settingsURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        // The temporary file is private from its creation, before atomic replacement.
        let temporary = directory.appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        if rename(temporary.path, url.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
