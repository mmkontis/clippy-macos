#!/usr/bin/env python3
"""Fetch the pinned Apache-2.0 Codex runtime at build preparation time, never at app runtime."""
import argparse, base64, hashlib, io, os, subprocess, tarfile, urllib.request
from pathlib import Path

VERSION = "0.153.4"
PACKAGES = {
    "arm64": ("arm64", "B1qhN3fa1ay0R0wGziXqgwSkB5icpYChNKHhtBHff/0UtSTC7z+l8aTtvMlGjH3E8HEvY3+njIJelM9CAAoVWg=="),
    "x86_64": ("x64", "vnSbbPzfoDZmmyzsxswsDDXQ06IVFBzkQU7/hroB3ji93Ok2utcsq8Psfk2tjF5r9mEx8RWFJhzuTGHG26/NDA=="),
}
parser = argparse.ArgumentParser()
parser.add_argument("--arch", choices=["arm64", "x86_64", "universal"], default="universal")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1] / ".build/codex"
arches = list(PACKAGES) if args.arch == "universal" else [args.arch]
for arch in arches:
    dest = root / arch
    target = dest / "codex"
    if target.exists() and (dest / "version").exists() and (dest / "version").read_text() == VERSION:
        continue
    package_arch, digest = PACKAGES[arch]
    data = urllib.request.urlopen(f"https://registry.npmjs.org/@openai/codex/-/codex-{VERSION}-darwin-{package_arch}.tgz").read()
    if base64.b64encode(hashlib.sha512(data).digest()).decode() != digest:
        raise RuntimeError("Codex package checksum mismatch")
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        member = next(m for m in archive if m.isfile() and m.name.endswith("/bin/codex"))
        with archive.extractfile(member) as src, target.open("wb") as dst:
            import shutil
            shutil.copyfileobj(src, dst)
    target.chmod(0o755)
    (dest / "version").write_text(VERSION)
    print(f"Verified Codex {VERSION} for {arch}")
if args.arch == "universal":
    dest = root / "universal"
    dest.mkdir(exist_ok=True)
    subprocess.run(["lipo", "-create", *(str(root/a/"codex") for a in arches), "-output", str(dest/"codex")], check=True)
    (dest / "version").write_text(VERSION)
