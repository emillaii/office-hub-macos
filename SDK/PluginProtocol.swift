import AppKit

/// Protocol version 1. Implement in an NSObject subclass named by NSPrincipalClass.
/// All lifecycle and UI calls take place on the main thread.
@MainActor @objc(OfficeHubPluginProtocol) public protocol OfficeHubPlugin: NSObjectProtocol {
    init()
    var statusSummary: String { get }
    func activate(context: OfficeHubContext) throws -> NSViewController
    func applyTheme(_ identifier: String)
    /// Validate unfinished work and ask about unsaved settings without stopping.
    func prepareToDeactivate() -> Bool
    /// Stop only resources owned by this plugin. Called after preparation succeeds.
    func deactivate()
    @objc optional func importPreviousSettings()
}

@MainActor @objc(OfficeHubHostServices) public protocol OfficeHubHostServices: NSObjectProtocol {
    func revealPlugin(_ identifier: String)
    func selectTheme(_ identifier: String)
}

@MainActor @objcMembers public final class OfficeHubContext: NSObject {
    public let identifier: String
    public let resourceDirectory: URL
    public let dataDirectory: URL
    public let window: NSWindow
    public weak var host: OfficeHubHostServices?
    public var themeIdentifier: String

    public init(identifier: String, resourceDirectory: URL, dataDirectory: URL,
                window: NSWindow, themeIdentifier: String, host: OfficeHubHostServices?) {
        self.identifier = identifier; self.resourceDirectory = resourceDirectory
        self.dataDirectory = dataDirectory; self.window = window
        self.themeIdentifier = themeIdentifier; self.host = host
        super.init()
    }
}
