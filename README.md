# Office Hub

A native macOS shell for Office Proxy, Mail Memo and future plugins. One app,
one window and one menu-bar entry, using Mail Memo’s Green, Dark, Ocean and
Amber terminal themes. Shell, shared SDK, plugin code and examples live in this
repository. Plugins are actual loadable native bundles, rather than shortcuts
that launch the original apps.

## Build and use

Requires macOS 14+, Xcode Command Line Tools and Python 3.9+. Mail Memo also
uses your existing signed-in Codex CLI and accounts configured in Apple Mail.
Office Proxy’s dedicated browser uses Google Chrome.

```bash
python3 Scripts/test.py
python3 Scripts/build.py --examples --smoke-test --install
open "$HOME/Applications/Office Hub.app"
```

The app is built at `build/Office Hub.app` and optionally installed in
`~/Applications`. Plugin packages are in `build/Plugins/*.officeplugin`.
Examples are built only with `--examples` and are not bundled into the app.
Builds are local, ad-hoc signed and target the current machine’s architecture.
They are not Developer ID signed or notarized for public distribution.

The two included plugins start disabled on first launch. Click **Enable & open**.
Enabled plugins continue running when you switch views or close the window.
Your enabled choices are restored at the next launch. Quitting Office Hub stops
its plugins. The app does not install LaunchAgents or change login items; open
Office Hub when needed or add it to macOS Login Items yourself.

## Office Proxy

The connection profiles, domain rules, public host-key verification, secure SSH
password prompt, saved-settings history and dedicated Chrome browser are reused
from Office Proxy. It routes selected destinations through an SSH SOCKS tunnel;
it does not change system proxy settings or the browser you normally use.

Office Hub has its own settings and browser profile. Its local HTTP proxy uses
**18181**, and its SSH SOCKS endpoint uses **1081**, so it can be evaluated beside
the original app (18081/1080). Enabling the plugin starts only the local proxy.
SSH login starts after you click Connect. Passwords are not saved.

Click **Import existing settings…** to copy standalone Office Proxy profiles,
rules and trusted public host keys. This does not copy Chrome sessions, change
the original files or stop the original app. Otherwise, enter connection settings
and verify the office host before connecting. Restart plugin and Disable stop
only the tunnel and worker owned by this plugin.

## Mail Memo

Summary, attention queue, Luna classification, read-only Mail collection,
notifications, deduplication and Hong Kong scheduling are reused from Mail Memo.
Choose **Use Apple Mail accounts** to load addresses already configured in Apple
Mail, then **Connect & check**. You can also enter addresses manually in
Preferences. Account discovery reads account metadata only; the connection check
reads inbox previews and creates a summary. Empty account lists keep checks paused
and show a setup banner. macOS may require Automation permission for
**Office Hub**, independently of the original Mail Memo permission. Notifications
also require permission. Neither permission is bypassed or granted automatically.

**Import existing settings…** copies accounts and preferences. Automatic checks
and Mail access remain paused until you explicitly connect in Office Hub. Import
does not modify standalone settings or copy old reports. Pause or quit standalone
Mail Memo before enabling checks here, to avoid duplicate summaries/notifications.

The schedule is checked inside the enabled plugin every minute, without separate
LaunchAgents. The Mac must be awake and Office Hub running. A running check must
finish before Mail Memo can be disabled or Office Hub can quit normally. The
plugin never sends, deletes, moves or marks mail as read. Headers and short previews
are submitted to Luna through your Codex sign-in; review the original mail before
acting on an automated classification.

## Plugin installation and data

Use **Plugin library → Install plugin…** to select a trusted `.officeplugin`
bundle. The host checks its manifest, bundle metadata, API version and signature,
then asks before installing it. New plugins remain disabled until enabled.
The included plugins may be disabled but are kept in the app bundle. An external
plugin may be removed after disabling it and restarting Office Hub; native code
cannot reliably unload from the running process. Saved plugin data is retained.

Native plugins run with the current user’s access inside Office Hub. Declared
capabilities describe their features; they are not a security sandbox. Install
only code you trust. Signature verification checks package integrity, not the
publisher’s trustworthiness for an ad-hoc signed local plugin.

Host state: `~/Library/Application Support/Office Hub/`.
External code: `Plugins/<id>.officeplugin` under that directory.
Private settings and runtime files: `Plugin Data/<id>/` under that directory.
Office Proxy’s short SSH socket lives in `~/Library/Caches/OfficeHub/Proxy/` to
stay below macOS UNIX socket path limits. Existing standalone installations and
their support folders are not changed by building/installing Office Hub.

## Extend it

```bash
python3 Scripts/new_plugin.py meeting-notes "Meeting Notes"
python3 Scripts/build.py --smoke-test
```

This creates `Plugins/MeetingNotes/` with a manifest and a working native view.
The build discovers plugin directories automatically; no host source changes
are required. The new package can also be distributed separately and installed
through Plugin library. See [PLUGIN_API.md](PLUGIN_API.md) for the versioned
lifecycle and shared theme contract. `Examples/ExampleTool` demonstrates it.

Imported code provenance is recorded in `SOURCE_ORIGINS.json`. Standalone project
source and installed apps are left intact. This repository contains no real
account lists, passwords, reports or browser profiles.
