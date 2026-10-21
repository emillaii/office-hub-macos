#!/usr/bin/env python3
"""Scaffold a native Office Hub plugin without editing the host."""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent

def create(slug, title, output=None):
    if not re.fullmatch(r'[a-z][a-z0-9]*(?:-[a-z0-9]+)*', slug):
        raise ValueError('Use a lowercase slug such as meeting-notes.')
    name = ''.join(part.capitalize() for part in slug.split('-'))
    identifier = 'local.officehub.' + slug
    entry = 'OfficeHub' + name + 'Plugin'
    destination = (output or ROOT / 'Plugins') / name
    destination.mkdir(parents=True, exist_ok=False)
    (destination / 'Sources').mkdir()
    metadata = dict(id=identifier, name=title, version='1.0.0', apiVersion=1,
                    module=name + 'Plugin', principalClass=entry, symbol='puzzlepiece.extension',
                    category='TOOLS', summary='A native Office Hub plugin.', capabilities=['Local user interface'])
    (destination / 'plugin.json').write_text(json.dumps(metadata, indent=2) + '\n')
    source = '''import AppKit
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
            Text(TITLE).font(.system(size: 26, weight: .bold, design: .monospaced))
            Text("A plugin view using Office Hub’s shared theme.").foregroundStyle(palette.muted)
            Text("Actions: \\(model.count)").font(.system(size: 18, design: .monospaced))
            Button("Try action") { model.count += 1 }.buttonStyle(HubButtonStyle(palette: palette, primary: true))
            Spacer()
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(palette.text).background(palette.background)
    }
}
@MainActor @objc(ENTRY) final class Plugin: NSObject, OfficeHubPlugin {
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
'''.replace('TITLE', json.dumps(title)).replace('ENTRY', entry)
    (destination / 'Sources/Plugin.swift').write_text(source)
    return destination

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('slug')
    parser.add_argument('title')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    print(create(args.slug, args.title, args.output))
