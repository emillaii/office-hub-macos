import AppKit
import SwiftUI
import OfficeHubPluginKit

struct PluginPane: NSViewControllerRepresentable {
    let controller: NSViewController
    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}

struct HubView: View {
    @ObservedObject var manager: PluginManager
    private var p: HubPalette { manager.theme.palette }
    private var current: PluginDescriptor? { manager.plugins.first { $0.id == manager.selected } }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(p.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("office-hub / \(current?.manifest.name.lowercased().replacingOccurrences(of: " ", with: "-") ?? manager.selected)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                        Text(current?.manifest.name ?? (manager.selected == "plugins" ? "Plugin library" : "Your office workspace"))
                            .font(.system(size: 23, weight: .semibold, design: .monospaced))
                    }
                    Spacer()
                    if manager.canImport {
                        Button("Import existing settings…", action: manager.importPreviousSettings)
                            .buttonStyle(HubButtonStyle(palette: p))
                    }
                    if let current, manager.enabled.contains(current.id) {
                        Text("[on]").foregroundStyle(p.accent)
                        Button("Disable") { manager.disable(current) }.buttonStyle(HubButtonStyle(palette: p))
                    }
                }.padding(25)
                Rectangle().fill(p.border).frame(height: 1)
                if let controller = manager.controllers[manager.selected] {
                    PluginPane(controller: controller).id(manager.selected).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if manager.selected == "home" { welcome }
                            HStack {
                                Text("INSTALLED PLUGINS").tracking(1.5).foregroundStyle(p.muted)
                                Spacer()
                                Button("Install plugin…", action: manager.install).buttonStyle(HubButtonStyle(palette: p))
                            }
                            ForEach(manager.plugins) { plugin in pluginCard(plugin) }
                            Text("Plugins stay active when you switch workspaces. Closing the window keeps Office Hub in the menu bar.")
                                .foregroundStyle(p.muted).font(.system(size: 11, design: .monospaced)).lineSpacing(5)
                        }.padding(28)
                    }
                }
                if !manager.message.isEmpty {
                    Rectangle().fill(p.border).frame(height: 1)
                    Text(manager.message).textSelection(.enabled).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.muted).padding(.horizontal, 24).padding(.vertical, 12)
                }
            }
        }
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(p.text)
        .background(p.background).tint(p.accent).preferredColorScheme(.dark)
        .frame(minWidth: 1080, minHeight: 780)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(">_").font(.system(size: 28, weight: .bold, design: .monospaced)).foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("OFFICE HUB").fontWeight(.bold).tracking(1.5)
                    Text("ONE SHELL · YOUR TOOLS").font(.system(size: 8, design: .monospaced)).tracking(1).foregroundStyle(p.muted)
                }
            }.padding(.vertical, 30)
            Text("WORKSPACE").font(.system(size: 9, design: .monospaced)).tracking(1.5).foregroundStyle(p.muted).padding(.bottom, 12)
            navigation("Overview", symbol: "square.grid.2x2", id: "home")
            ForEach(manager.plugins) { plugin in
                navigation(plugin.manifest.name, symbol: plugin.manifest.symbol, id: plugin.id)
            }
            Rectangle().fill(p.border).frame(height: 1).padding(.vertical, 22)
            navigation("Plugin library", symbol: "puzzlepiece.extension", id: "plugins")
            Spacer(minLength: 20)
            HStack { Circle().fill(p.accent).frame(width: 5, height: 5); Text("\(manager.enabled.count) PLUGINS ACTIVE").tracking(1) }
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(p.accent).padding(.bottom, 16)
            Rectangle().fill(p.border).frame(height: 1).padding(.bottom, 16)
            Text("APPEARANCE").font(.system(size: 9, design: .monospaced)).tracking(1.2).foregroundStyle(p.muted)
            Picker("Theme", selection: Binding(get: { manager.theme.rawValue }, set: manager.selectTheme)) {
                ForEach(HubTheme.allCases) { theme in Text(theme.title).tag(theme.rawValue) }
            }.labelsHidden().padding(.top, 8)
            Text("Plugin API v1 · macOS").font(.system(size: 9, design: .monospaced)).foregroundStyle(p.muted).padding(.top, 16)
        }.padding(.horizontal, 20).padding(.bottom, 24).frame(width: 210).frame(maxHeight: .infinity).background(p.sidebar)
    }
    private func navigation(_ title: String, symbol: String, id: String) -> some View {
        Button {
            if manager.plugins.contains(where: { $0.id == id }) && !manager.enabled.contains(id) { manager.selected = "plugins" }
            else { manager.selected = id }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
                if manager.enabled.contains(id) { Circle().fill(p.accent).frame(width: 4, height: 4) }
            }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .foregroundStyle(manager.selected == id ? p.accent : p.muted)
                .background(manager.selected == id ? p.panel : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("YOUR TOOLS, TOGETHER.").font(.system(size: 10, design: .monospaced)).tracking(1.5).foregroundStyle(p.accent)
            Text("One app. Room to grow.").font(.system(size: 29, weight: .semibold, design: .monospaced))
            Text("Connect to your office network, keep up with your inbox, and add new tools as plugins.")
                .foregroundStyle(p.muted).lineSpacing(6)
            HStack(spacing: 24) {
                Text("\(manager.plugins.count) installed"); Text("\(manager.enabled.count) enabled"); Text("Shared Mail Memo themes")
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(p.accent)
        }.padding(25).frame(maxWidth: .infinity, alignment: .leading)
            .background(p.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
    }
    private func pluginCard(_ plugin: PluginDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: plugin.manifest.symbol).font(.system(size: 24)).foregroundStyle(p.accent)
                    .frame(width: 50, height: 50).background(p.inset, in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 7) {
                    Text(plugin.manifest.category).tracking(1.2).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.muted)
                    Text(plugin.manifest.name).font(.system(size: 18, weight: .semibold, design: .monospaced))
                    Text(plugin.manifest.summary).foregroundStyle(p.muted).lineSpacing(4)
                }
                Spacer(minLength: 12)
                Text("v" + plugin.manifest.version).foregroundStyle(p.muted).font(.system(size: 10, design: .monospaced))
            }
            Text(plugin.manifest.capabilities.joined(separator: " · ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
            Rectangle().fill(p.border).frame(height: 1)
            HStack(spacing: 12) {
                Text(manager.enabled.contains(plugin.id) ? (manager.statuses[plugin.id] ?? "Enabled") : "Installed · disabled")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(manager.enabled.contains(plugin.id) ? p.accent : p.muted)
                Spacer()
                if manager.enabled.contains(plugin.id) {
                    Button("Open") { manager.revealPlugin(plugin.id) }.buttonStyle(HubButtonStyle(palette: p, primary: true))
                    Button("Disable") { manager.disable(plugin) }.buttonStyle(HubButtonStyle(palette: p))
                } else {
                    Button("Enable & open") { manager.enable(plugin) }.buttonStyle(HubButtonStyle(palette: p, primary: true))
                    if !plugin.bundled { Button("Remove") { manager.remove(plugin) }.buttonStyle(HubButtonStyle(palette: p)) }
                }
            }
        }.padding(22).background(p.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
    }
}
