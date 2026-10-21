import AppKit
import SwiftUI
import OfficeHubPluginKit

@MainActor final class Model: ObservableObject {
    @Published var count = 0
    @Published var theme = HubTheme.hackerGreen
}
struct ToolView: View {
    @ObservedObject var model: Model
    var body: some View {
        let palette = model.theme.palette
        VStack(alignment: .leading, spacing: 20) {
            Text("Example Tool").font(.system(size: 26, weight: .bold, design: .monospaced))
            Text("A plugin view using Office Hub’s shared theme.").foregroundStyle(palette.muted)
            Text("Actions: \(model.count)").font(.system(size: 18, design: .monospaced))
            Button("Try action") { model.count += 1 }.buttonStyle(HubButtonStyle(palette: palette, primary: true))
            Spacer()
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(palette.text).background(palette.background)
    }
}
@MainActor @objc(OfficeHubExampleToolPlugin) final class Plugin: NSObject, OfficeHubPlugin {
    override init() { super.init() }
    private var model: Model?
    var statusSummary: String { "Ready" }
    func activate(context: OfficeHubContext) throws -> NSViewController {
        let model = Model(); self.model = model
        model.theme = HubTheme(rawValue: context.themeIdentifier) ?? .hackerGreen
        return NSHostingController(rootView: ToolView(model: model))
    }
    func applyTheme(_ identifier: String) { model?.theme = HubTheme(rawValue: identifier) ?? .hackerGreen }
    func prepareToDeactivate() -> Bool { true }
    func deactivate() { model = nil }
}
