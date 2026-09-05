#!/usr/bin/env python3
"""Package an Xcode-notarized direct app without exporting authentication secrets."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile

def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--sparkle-bin', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='clippy-notarized-package-') as folder:
        export = Path(folder) / 'export'
        run('xcodebuild', '-exportNotarizedApp', '-archivePath', args.archive.resolve(), '-exportPath', export)
        app = export / 'Clippy.app'
        run('codesign', '--verify', '--deep', '--strict', app)
        run('xcrun', 'stapler', 'validate', app)
        run('spctl', '--assess', '--type', 'execute', app)
        with (app / 'Contents/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        if info['CFBundleIdentifier'] != 'com.clippy.app':
            raise ValueError('Only direct-download builds belong here')
        if info['SUFeedURL'] != 'https://raw.githubusercontent.com/mmkontis/clippy-macos/main/appcast.xml':
            raise ValueError('Unexpected update feed')
        if info['SUPublicEDKey'] != run(args.sparkle_bin / 'generate_keys', '-p'):
            raise ValueError('Preserve the existing Sparkle key')
        if set(run('lipo', '-archs', app / 'Contents/MacOS/Clippy').split()) != {'arm64', 'x86_64'}:
            raise ValueError('A universal build is required')
        release = root / 'release'
        release.mkdir(exist_ok=True)
        output = Path(folder) / f"Clippy-{info['CFBundleShortVersionString']}.zip"
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, output)
        signature = run(args.sparkle_bin / 'sign_update', '-p', output)
        run(args.sparkle_bin / 'sign_update', '--verify', output, signature)
        checksum = hashlib.sha256(output.read_bytes()).hexdigest()
        # Re-extract exactly what users receive and verify its stapled ticket and signature.
        extracted = Path(folder) / 'verified'
        run('ditto', '-x', '-k', output, extracted)
        run('codesign', '--verify', '--deep', '--strict', extracted / 'Clippy.app')
        run('xcrun', 'stapler', 'validate', extracted / 'Clippy.app')
        run('spctl', '--assess', '--type', 'execute', extracted / 'Clippy.app')
        destination = release / output.name
        destination.write_bytes(output.read_bytes())
        destination.with_suffix('.signature.txt').write_text(signature + '\n')
        destination.with_suffix('.sha256').write_text(checksum + '  ' + output.name + '\n')
        print('Verified download: ' + str(destination))

if __name__ == '__main__':
    main()
