import Foundation

@main
struct SettingsTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let legacy = Data(#"{"host":"old.example.com","port":2222,"username":"alice","domains":["*.office.test"],"home":"https://office.test/"}"#.utf8)
        var settings = try decoder.decode(Settings.self, from: legacy)
        precondition(settings.profiles.count == 1)
        precondition(settings.host == "old.example.com" && settings.port == 2222 && settings.username == "alice")
        precondition(settings.selectedProfile.hostKeyAlias == "office-proxy-pc")
        precondition(settings.selectedProfile.knownHostsFilename == "office_known_hosts")
        let originalID = settings.selectedProfileID
        let other = ConnectionProfile(name: "Second", host: "second.example.com", port: 2200, username: "bob")
        settings.profiles.append(other); settings.selectedProfileID = other.id
        settings.host = "updated.example.com"; settings.port = 2223; settings.username = "carol"
        precondition(settings.profiles[0].host == "old.example.com")
        precondition(settings.profiles[0].port == 2222 && settings.profiles[0].username == "alice")
        precondition(settings.selectedProfile.knownHostsFilename != settings.profiles[0].knownHostsFilename)
        precondition(settings.selectedProfile.hostKeyAlias != settings.profiles[0].hostKeyAlias)
        let restored = try decoder.decode(Settings.self, from: JSONEncoder().encode(settings))
        precondition(restored.selectedProfileID == other.id && restored.profiles.count == 2)
        precondition(restored.host == "updated.example.com" && restored.port == 2223 && restored.username == "carol")
        precondition(restored.domains == ["*.office.test"] && restored.home == "https://office.test/")
        settings.selectedProfileID = originalID
        precondition(settings.host == "old.example.com")
        settings.profiles.removeFirst(); settings.selectedProfileID = UUID()
        let fallback = try decoder.decode(Settings.self, from: JSONEncoder().encode(settings))
        precondition(fallback.selectedProfileID == other.id)
        let empty = try decoder.decode(Settings.self, from: Data(#"{"profiles":[]}"#.utf8))
        precondition(empty.profiles.count == 1 && empty.host == "office.example.com")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory, historyLimit: 3)
        let initial = restored
        try store.save(initial)
        precondition(try! store.history().isEmpty)
        try store.save(initial)
        precondition(try! store.history().isEmpty)
        var edited = initial
        edited.host = "typo.example.com"; edited.domains = ["wrong.example.com"]
        edited.profiles.removeFirst()
        try store.save(edited)
        let history = try store.history()
        precondition(history.count == 1 && history[0].settings == initial)
        precondition(try! store.load() == edited)
        // A rollback is itself reversible, including deleted profiles and domain rules.
        try store.save(history[0].settings)
        precondition(try! store.load() == initial)
        precondition(try! store.history()[0].settings == edited)
        for index in 0..<5 {
            edited.host = "host-\(index).example.com"
            try store.save(edited)
        }
        precondition(try! store.history().count == 3)
        for url in [store.settingsURL, store.historyURL] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
            precondition(permissions.intValue == 0o600)
        }
        let beforeFailure = try Data(contentsOf: store.settingsURL)
        try Data("broken history".utf8).write(to: store.historyURL)
        do {
            try store.save(initial)
            preconditionFailure("Saving should stop if history cannot be preserved")
        } catch { }
        precondition(try! Data(contentsOf: store.settingsURL) == beforeFailure)
        try Data("broken settings".utf8).write(to: store.settingsURL)
        do {
            try store.save(initial)
            preconditionFailure("Unreadable settings must not be overwritten")
        } catch { }
        precondition(try! Data(contentsOf: store.settingsURL) == Data("broken settings".utf8))
        print("Settings migration, profile isolation, persistence, history, rollback, and failure protection passed.")
    }
}
