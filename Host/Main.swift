import AppKit
import SwiftUI
import UserNotifications
import OfficeHubPluginKit
import Darwin

@MainActor final class HubAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var manager: PluginManager!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    private var lockFD: Int32 = -1
    func applicationDidFinishLaunching(_ notification: Notification) {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Office Hub")
        do { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { fatalError(error.localizedDescription) }
        lockFD = Darwin.open(support.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("OfficeHub.reveal"), object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        manager = PluginManager(support: support)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Office Hub"; window.minSize = NSSize(width: 1080, height: 810)
        window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        manager.window = window; window.contentView = NSHostingView(rootView: HubView(manager: manager))
        window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Office Hub")
        let menu = NSMenu()
        for (name, action) in [("Open Office Hub", #selector(showWindow)), ("Plugin library", #selector(showPlugins))] {
            menu.addItem(withTitle: name, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Office Hub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        let main = NSMenu(); let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Open Office Hub", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "Plugin library", action: #selector(showPlugins), keyEquivalent: ",").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Quit Office Hub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; main.addItem(app)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        for (name, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
                                  ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
                                  ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: name, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
        UNUserNotificationCenter.current().delegate = self
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showWindow), name: Notification.Name("OfficeHub.reveal"), object: nil)
        manager.restoreEnabledPlugins()
        showWindow()
    }
    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showPlugins() { manager.selected = "plugins"; showWindow() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        manager == nil || manager.prepareToQuit() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { manager?.stopAll(); if lockFD >= 0 { Darwin.close(lockFD) } }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) { completion([.banner, .sound, .list]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completion: @escaping () -> Void) {
        let identifier = response.notification.request.content.userInfo["officeHubPluginID"] as? String
        Task { @MainActor in if let identifier { self.manager.revealPlugin(identifier) }; self.showWindow(); completion() }
    }
}

@main struct Main {
    @MainActor static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--validate-plugin") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OfficeHubSmoke-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let manager = PluginManager(support: folder)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860), styleMask: [.titled], backing: .buffered, defer: false)
            manager.window = window
            precondition(manager.plugins.count >= 2, "Bundled plugins were not found")
            if let index = CommandLine.arguments.firstIndex(of: "--validate-plugin"), index + 1 < CommandLine.arguments.count {
                let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                do {
                    let manifest = try PluginManifest.read(at: url)
                    manager.plugins = [PluginDescriptor(manifest: manifest, url: url, bundled: false)]
                } catch { fatalError(error.localizedDescription) }
            }
            for descriptor in manager.plugins {
                manager.enable(descriptor)
                precondition(manager.enabled.contains(descriptor.id), manager.message)
                manager.selectTheme("ocean")
                manager.disable(descriptor)
                precondition(!manager.enabled.contains(descriptor.id), manager.message)
            }
            print("Plugin discovery, native bundle loading, activation, theme updates and shutdown passed.")
            return
        }
        application.setActivationPolicy(.regular)
        let delegate = HubAppDelegate(); application.delegate = delegate
        application.run(); withExtendedLifetime(delegate) {}
    }
}
