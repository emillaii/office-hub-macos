import Foundation

@main struct ManifestTests {
    static func main() throws {
        let base: [String: Any] = ["id": "local.officehub.test", "name": "Test", "version": "1.0.0", "apiVersion": 1,
            "module": "TestPlugin", "principalClass": "OfficeHubTestPlugin", "symbol": "puzzlepiece.extension",
            "category": "TEST", "summary": "Test plugin", "capabilities": ["Local interface"]]
        func decode(_ values: [String: Any]) throws -> PluginManifest {
            try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: values))
        }
        try decode(base).validate()
        for invalidID in ["../../outside", "../test", "local/test", "LOCAL.Test", "", ".hidden"] {
            var changed = base; changed["id"] = invalidID
            do { try decode(changed).validate(); preconditionFailure("Unsafe identifier accepted") } catch { }
        }
        var incompatible = base; incompatible["apiVersion"] = 2
        do { try decode(incompatible).validate(); preconditionFailure("Unsupported protocol accepted") } catch { }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = folder.appendingPathComponent("test.officeplugin")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: base).write(to: bundle.appendingPathComponent("Contents/Resources/plugin.json"))
        var info: [String: Any] = ["CFBundleIdentifier": "local.officehub.test", "CFBundleShortVersionString": "1.0.0", "NSPrincipalClass": "OfficeHubTestPlugin"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let accepted = try PluginManifest.read(at: bundle)
        precondition(accepted.id == "local.officehub.test")
        info["CFBundleIdentifier"] = "local.officehub.something-else"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        do { _ = try PluginManifest.read(at: bundle); preconditionFailure("Metadata mismatch accepted") } catch { }
        let link = folder.appendingPathComponent("link.officeplugin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
        do { _ = try PluginManifest.read(at: link); preconditionFailure("Symbolic-link plugin accepted") } catch { }
        print("Plugin identifiers, API compatibility, bundle metadata and symbolic-link validation passed.")
    }
}
