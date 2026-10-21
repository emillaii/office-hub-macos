# Office Hub plugin API, version 1

The contract is implemented in `SDK/PluginProtocol.swift` and exported by the
`OfficeHubPluginKit` framework embedded in Office Hub. Plugins are Swift/AppKit
native `.officeplugin` bundles. SwiftUI views are embedded in `NSHostingController`.
Build against the SDK and Swift toolchain used for your installed host; rebuild
plugins when upgrading that toolchain. Each plugin compiles into its own module,
so internal names such as `Settings` do not collide across plugins.

```swift
@MainActor @objc(OfficeHubPluginProtocol)
public protocol OfficeHubPlugin: NSObjectProtocol {
    init()
    var statusSummary: String { get }
    func activate(context: OfficeHubContext) throws -> NSViewController
    func applyTheme(_ identifier: String)
    func prepareToDeactivate() -> Bool
    func deactivate()
    @objc optional func importPreviousSettings()
}
```

Implement this in an `NSObject` subclass with an explicit `override init()` and
a globally unique Objective-C name, for example `@objc(OfficeHubMeetingNotesPlugin)`.
Set that name as both `principalClass` in `plugin.json` and `NSPrincipalClass` in
the generated Info.plist. The host checks metadata before loading native code.
The build script creates the Info.plist and signs the package automatically.

## Lifecycle

1. Discovery reads `plugin.json`; it does not activate the plugin.
2. Enable verifies the signature and loads the bundle’s principal class. `init`
   must be side-effect free.
3. `activate` receives the context, creates owned resources and returns the main
   view controller. Do not create another app, main window or menu-bar icon.
   Clean up partial initialization when throwing; `deactivate` must be safe if
   activation failed or resources are already stopped.
4. `applyTheme` updates the plugin’s view whenever the host theme changes.
5. Switching workspaces hides the view without stopping the plugin. Background
   work continues while enabled.
6. `prepareToDeactivate` checks pending work/unsaved settings and may ask the user
   how to proceed. Return false to cancel. It must not stop resources itself.
   On quit the host prepares every enabled plugin before stopping any of them.
7. `deactivate` stops timers, observers, workers and connections owned by the
   plugin. Keep saved data. Do not terminate the host or another plugin.

Lifecycle/UI calls run on the main actor. Dispatch blocking I/O off the main
thread. Keep statusSummary quick; the host polls it every three seconds.
Native code stays loaded after Disable, but its controller/context are released.
The plugin must support a later activation using a fresh context.

## Context and services

`OfficeHubContext` provides `identifier`, `resourceDirectory`, `dataDirectory`,
`window`, `themeIdentifier` and a weak `host` reference.

- Read immutable packaged resources from resourceDirectory, not Bundle.main
  (which refers to the shell).
- Store settings/runtime files only in the supplied private dataDirectory or
  another documented plugin-owned location. Do not use standalone app state by
  default. Use atomic writes and restrictive permissions for personal data.
- Use window for sheets and editing; `host.revealPlugin(id)` opens the shared
  window. `host.selectTheme(id)` changes the shared appearance.
- Use the existing AppKit/SwiftUI APIs for native permissions and notifications.
  Put `officeHubPluginID: context.identifier` in notification userInfo so clicking
  the notification opens the correct workspace. Request permissions only after
  a relevant user action, and declare host entitlements/usage descriptions when
  adding a new protected macOS capability.

## Shared appearance

The SDK exports `HubTheme`, `HubPalette` and `HubButtonStyle`, using Mail Memo’s
original four palettes. Use `HubTheme(rawValue: context.themeIdentifier)` on
activation and update it in applyTheme. The raw values are `hacker-green`, `dark`,
`ocean` and `amber`. Use monospaced typography and the palette’s background,
panel, border, accent, text and muted colors. The scaffold shows a complete view.

## Package layout and manifest

Source layout:

```text
Plugins/MyTool/
  plugin.json
  Sources/*.swift
  Resources/*                 # optional immutable resources
  Helpers/HelperName/*.swift  # optional short-lived native helpers
```

`plugin.json` contains `id`, `name`, `version` (three numeric components),
`apiVersion` (1), `module`, `principalClass`, `symbol` (SF Symbol), `category`,
`summary`, and `capabilities` (feature descriptions). Use a unique lowercase
reverse-domain ID. IDs cannot contain paths. Future incompatible APIs must use
a different apiVersion; the v1 host rejects them rather than guessing.

The build emits `Contents/MacOS/<module>`, resources including plugin.json, and
Info.plist inside `<id>.officeplugin`. Local installers require a complete signed
bundle without symbolic links. The shared SDK framework stays in the host,
rather than being duplicated in every plugin. Capabilities are descriptive, not
an isolation boundary: plugins execute native code with the host user’s access.

The host has no hard-coded Office Proxy/Mail Memo switch for loading plugins.
To add a source plugin, scaffold it and rebuild. To add a compiled plugin, use
the library installer. Bundled IDs cannot be overridden by external packages.
New versions of a loaded external plugin require disabling, quitting/restarting,
and replacing the package; do not overwrite a loaded binary in place.

## Validate

```bash
python3 Scripts/test.py
python3 Scripts/build.py --examples --smoke-test
"build/Office Hub.app/Contents/MacOS/OfficeHub" \
  --validate-plugin build/Plugins/local.officehub.example-tool.officeplugin
```

Validation loads and activates that plugin using a temporary data directory,
applies a theme, and deactivates it. Only validate trusted code. Live Mail/SSH
authentication is deliberately outside the local smoke tests.
