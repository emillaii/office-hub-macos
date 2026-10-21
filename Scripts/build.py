#!/usr/bin/env python3
"""Build one native host and discover/compile plugins from this repository."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import re
import uuid
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'build'
APP = BUILD / 'Office Hub.app'
TARGET = platform.machine() + '-apple-macosx14.0'

def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)

def plist(path, **values):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(values))

def sign(path, entitlements=None):
    args = ['codesign', '--force', '--sign', '-']
    if entitlements:
        args += ['--entitlements', str(entitlements)]
    run(*args, path)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--smoke-test', action='store_true')
    parser.add_argument('--examples', action='store_true', help='Also build example plugin packages, without bundling them into the app')
    args = parser.parse_args()
    BUILD.mkdir(exist_ok=True)
    if APP.exists():
        shutil.rmtree(APP)
    contents = APP / 'Contents'
    for name in ['MacOS', 'Resources', 'Frameworks', 'PlugIns']:
        (contents / name).mkdir(parents=True)
    framework = contents / 'Frameworks/OfficeHubPluginKit.framework'
    version = framework / 'Versions/A'
    modules = version / 'Modules/OfficeHubPluginKit.swiftmodule'
    modules.mkdir(parents=True)
    plist(version / 'Resources/Info.plist', CFBundleIdentifier='local.officehub.plugin-kit',
          CFBundleName='OfficeHubPluginKit', CFBundleExecutable='OfficeHubPluginKit',
          CFBundlePackageType='FMWK', CFBundleVersion='1', CFBundleShortVersionString='1.0.0')
    (framework / 'Versions/Current').symlink_to('A')
    for name in ['Resources', 'Modules', 'OfficeHubPluginKit']:
        (framework / name).symlink_to('Versions/Current/' + name)
    common = ['xcrun', 'swiftc', '-swift-version', '5', '-target', TARGET]
    run(*common, '-parse-as-library', '-emit-library', '-emit-module', '-module-name', 'OfficeHubPluginKit',
        '-emit-module-path', modules / (platform.machine() + '-apple-macos.swiftmodule'),
        '-Xlinker', '-install_name', '-Xlinker', '@rpath/OfficeHubPluginKit.framework/Versions/A/OfficeHubPluginKit',
        *sorted((ROOT / 'SDK').glob('*.swift')), '-o', version / 'OfficeHubPluginKit',
        '-framework', 'AppKit', '-framework', 'SwiftUI')
    sign(framework)
    packages = BUILD / 'Plugins'
    if packages.exists():
        shutil.rmtree(packages)
    packages.mkdir()
    identifiers = set()
    directories = sorted((ROOT / 'Plugins').iterdir())
    if args.examples:
        directories += sorted((ROOT / 'Examples').iterdir())
    for directory in directories:
        if not (directory / 'plugin.json').is_file():
            continue
        metadata = json.loads((directory / 'plugin.json').read_text())
        for key, pattern in [('id', r'[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+'), ('module', r'[A-Za-z][A-Za-z0-9_]*'), ('principalClass', r'[A-Za-z][A-Za-z0-9_]*'), ('version', r'\d+\.\d+\.\d+')]:
            if not isinstance(metadata.get(key), str) or not re.fullmatch(pattern, metadata[key]):
                raise ValueError(f'Invalid plugin {key} in {directory}')
        if metadata.get('apiVersion') != 1:
            raise ValueError(f'Unsupported plugin API in {directory}')
        if metadata['id'] in identifiers:
            raise ValueError('Duplicate plugin ID: ' + metadata['id'])
        identifiers.add(metadata['id'])
        bundle = packages / (metadata['id'] + '.officeplugin')
        binary = bundle / 'Contents/MacOS'
        resources = bundle / 'Contents/Resources'
        binary.mkdir(parents=True); resources.mkdir()
        if (directory / 'Resources').exists():
            shutil.copytree(directory / 'Resources', resources, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns('__pycache__', 'test_*', '*.pyc'))
        shutil.copy2(directory / 'plugin.json', resources / 'plugin.json')
        if (resources / 'askpass.sh').exists():
            (resources / 'askpass.sh').chmod(0o755)
        for helper in sorted((directory / 'Helpers').glob('*')) if (directory / 'Helpers').exists() else []:
            if helper.is_dir():
                run(*common, *sorted(helper.glob('*.swift')), '-framework', 'AppKit', '-o', binary / helper.name)
                sign(binary / helper.name)
        run(*common, '-parse-as-library', '-emit-library', '-module-name', metadata['module'],
            '-F', contents / 'Frameworks', '-framework', 'OfficeHubPluginKit',
            *sorted((directory / 'Sources').glob('*.swift')), '-o', binary / metadata['module'],
            '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'UserNotifications', '-framework', 'Network')
        plist(bundle / 'Contents/Info.plist', CFBundleIdentifier=metadata['id'], CFBundleName=metadata['name'],
              CFBundleExecutable=metadata['module'], CFBundlePackageType='BNDL',
              CFBundleVersion='1', CFBundleShortVersionString=metadata['version'],
              NSPrincipalClass=metadata['principalClass'], LSMinimumSystemVersion='14.0')
        sign(bundle)
        if directory.parent.name == 'Plugins':
            shutil.copytree(bundle, contents / 'PlugIns' / bundle.name)
    run(*common, '-parse-as-library', '-F', contents / 'Frameworks', '-framework', 'OfficeHubPluginKit',
        '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
        *sorted((ROOT / 'Host').glob('*.swift')), '-o', contents / 'MacOS/OfficeHub',
        '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'UserNotifications')
    plist(contents / 'Info.plist', CFBundleIdentifier='local.officehub.app', CFBundleName='Office Hub',
          CFBundleDisplayName='Office Hub', CFBundleExecutable='OfficeHub', CFBundlePackageType='APPL',
          CFBundleShortVersionString='1.0.0', CFBundleVersion='1', LSMinimumSystemVersion='14.0',
          NSHighResolutionCapable=True, CFBundleIconFile='OfficeHub.icns',
          NSAppleEventsUsageDescription='The Mail Memo plugin reads headers and short previews from Apple Mail to create summaries. It never sends, deletes or changes message flags.')
    icon = BUILD / 'OfficeHub.iconset'
    icon.mkdir(exist_ok=True)
    run('xcrun', 'swift', ROOT / 'Scripts/MakeIcon.swift', icon)
    run('iconutil', '-c', 'icns', icon, '-o', contents / 'Resources/OfficeHub.icns')
    sign(APP, ROOT / 'Host/entitlements.plist')
    run('codesign', '--verify', '--deep', '--strict', APP)
    print('Built:', APP, flush=True)
    if args.smoke_test:
        run(contents / 'MacOS/OfficeHub', '--smoke-test')
        if args.examples:
            for example in sorted((ROOT / 'Examples').iterdir()):
                metadata = json.loads((example / 'plugin.json').read_text())
                run(contents / 'MacOS/OfficeHub', '--validate-plugin', packages / (metadata['id'] + '.officeplugin'))
    if args.install:
        target = Path.home() / 'Applications/Office Hub.app'
        running = subprocess.run(['pgrep', '-f', '/Office Hub.app/Contents/MacOS/OfficeHub'], capture_output=True)
        if running.returncode == 0:
            raise RuntimeError('Quit Office Hub before replacing its installed app. The existing installation was kept.')
        target.parent.mkdir(exist_ok=True)
        staging = target.with_name('Office Hub.install-' + uuid.uuid4().hex + '.app')
        shutil.copytree(APP, staging, symlinks=True)
        run('codesign', '--verify', '--deep', '--strict', staging)
        backup = target.with_name('Office Hub.previous-' + uuid.uuid4().hex[:8] + '.app')
        if target.exists():
            target.rename(backup)
        try:
            staging.rename(target)
        except Exception:
            if backup.exists() and not target.exists():
                backup.rename(target)
            raise
        print('Installed:', target)

if __name__ == '__main__':
    main()
