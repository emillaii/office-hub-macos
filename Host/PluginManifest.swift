import Foundation

struct PluginManifest: Codable {
    let id: String
    let name: String
    let version: String
    let apiVersion: Int
    let module: String
    let principalClass: String
    let symbol: String
    let category: String
    let summary: String
    let capabilities: [String]

    func validate() throws {
        guard id.range(of: #"^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$"#, options: .regularExpression) != nil,
              id.count < 120, !name.isEmpty, name.count <= 80,
              version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              module.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
              principalClass.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
              summary.count <= 500, capabilities.count <= 20,
              capabilities.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else {
            throw PluginError.invalid("The plugin manifest contains invalid identifiers or descriptions.")
        }
        guard apiVersion == 1 else { throw PluginError.invalid("This plugin requires API version \(apiVersion). Office Hub supports version 1.") }
    }

    static func read(at bundle: URL) throws -> PluginManifest {
        guard bundle.pathExtension == "officeplugin" else { throw PluginError.invalid("Choose an .officeplugin bundle.") }
        guard try bundle.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw PluginError.invalid("Choose the actual plugin bundle, rather than a symbolic link.")
        }
        let resources = bundle.appendingPathComponent("Contents/Resources/plugin.json")
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: resources))
        try manifest.validate()
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == manifest.id,
              info["NSPrincipalClass"] as? String == manifest.principalClass,
              info["CFBundleShortVersionString"] as? String == manifest.version else {
            throw PluginError.invalid("Bundle metadata does not match the plugin manifest.")
        }
        return manifest
    }
}

enum PluginError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let value): return value } }
}

struct PluginDescriptor: Identifiable {
    let manifest: PluginManifest
    let url: URL
    let bundled: Bool
    var id: String { manifest.id }
}
