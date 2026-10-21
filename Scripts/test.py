#!/usr/bin/env python3
"""Local checks only: no office SSH login and no real inbox/model calls."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'build'
BUILD.mkdir(exist_ok=True)
env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
checks = [
    ['python3', '-m', 'unittest', 'discover', '-s', 'Tests', '-p', 'test_*.py', '-v'],
    ['python3', '-m', 'unittest', 'discover', '-s', 'Plugins/MailMemo/Resources', '-p', 'test_*.py', '-v'],
    ['xcrun', 'swiftc', '-swift-version', '5', 'Host/PluginManifest.swift', 'Tests/ManifestTests.swift', '-o', 'build/ManifestTests'],
    ['build/ManifestTests'],
    ['xcrun', 'swiftc', '-swift-version', '5', 'Plugins/OfficeProxy/Sources/Settings.swift', 'Tests/SettingsTests.swift', '-o', 'build/SettingsTests'],
    ['build/SettingsTests'],
]
for check in checks:
    subprocess.run(check, cwd=ROOT, env=env, check=True)
print('Unit and protocol validation checks passed. Build with --smoke-test to exercise native plugin loading.')
