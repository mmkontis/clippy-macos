#!/usr/bin/env python3
"""Refresh the public snapshot from Coworker's canonical sibling package."""
from pathlib import Path
import argparse
import hashlib
import shutil

parser = argparse.ArgumentParser()
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = root.parent / "ClipboardKit"
target = root / "Packages/ClipboardKit"
if not (source / "Package.swift").is_file():
    raise SystemExit("Canonical ../ClipboardKit is unavailable. Standalone builds use the bundled Packages/ClipboardKit snapshot.")

def files(folder):
    paths = [folder / "Package.swift", *sorted((folder / "Sources").rglob("*.swift")), *sorted((folder / "Tests").rglob("*.swift"))]
    return {str(path.relative_to(folder)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}

if args.check:
    if files(source) != files(target):
        raise SystemExit("ClipboardKit differs. Run scripts/sync-clipboard-kit.py and review the diff.")
    print("ClipboardKit snapshot matches the canonical shared source.")
else:
    shutil.copy2(source / "Package.swift", target / "Package.swift")
    shutil.rmtree(target / "Sources")
    shutil.copytree(source / "Sources", target / "Sources")
    if (source / "Tests").exists():
        if (target / "Tests").exists(): shutil.rmtree(target / "Tests")
        shutil.copytree(source / "Tests", target / "Tests")
    print("Updated ClipboardKit snapshot. Review, build, and commit it with the app release.")
