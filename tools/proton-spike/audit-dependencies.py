#!/usr/bin/env python3
"""Inventory shipped helper modules and retain their source license notices.

Run after prepare.sh; only reads dependency source, never application data.
This is an evidence collector, not a license or telemetry proof engine.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
go = os.environ.get("GO_BIN", "go")

def command(*args):
    return subprocess.check_output([go, *args], cwd=root, text=True)

def objects(source):
    decoder = json.JSONDecoder()
    while source.strip():
        value, end = decoder.raw_decode(source.lstrip())
        yield value
        source = source.lstrip()[end:]

# Union architectures used by the app; test-only packages are deliberately absent.
modules, packages = {}, {}
for arch in ("arm64", "amd64"):
    env = dict(os.environ, GOOS="darwin", GOARCH=arch, CGO_ENABLED="0")
    source = subprocess.check_output([go, "list", "-mod=readonly", "-deps", "-json", "./cmd/pigi-proton-helper"], cwd=root, env=env, text=True)
    for package in objects(source):
        packages[package["ImportPath"]] = package
        module = package.get("Module")
        if module and not module.get("Main"):
            modules[module["Path"]] = module

inventory, notices = [], []
for name, module in sorted(modules.items()):
    resolved = module.get("Replace", module)
    directory = Path(resolved["Dir"])
    version = resolved.get("Version")
    if name == "github.com/ProtonMail/go-proton-api":
        version = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=directory, text=True).strip()
    license_files = sorted(path for path in directory.rglob("*") if path.is_file() and path.name.lower().startswith(("license", "copying", "notice")) and ".git" not in path.parts)
    if not license_files:
        raise SystemExit(f"No license notice found: {name}")
    entry = dict(module=name, source=resolved["Path"] if module.get("Replace") else name, version=version, notices=[])
    for path in license_files:
        data = path.read_bytes()
        relative = str(path.relative_to(directory))
        entry["notices"].append(dict(file=relative, sha256=hashlib.sha256(data).hexdigest()))
        notices.append(f"=== {name} {version}: {relative} ===\n" + data.decode("utf-8") + "\n")
    inventory.append(entry)

goroot = Path(command("env", "GOROOT").strip())
golang_license = goroot / "LICENSE"
if not golang_license.exists():  # Homebrew relocates the toolchain license.
    golang_license = goroot.parent / "LICENSE"
notices.append("=== Go standard library: LICENSE ===\n" + golang_license.read_text())
for path in sorted((goroot / "src/vendor").rglob("LICENSE*")):
    notices.append(f"=== Go standard library vendor: {path.relative_to(goroot)} ===\n" + path.read_text())
(output / "proton-third-party-notices.txt").write_text("\n".join(notices))
(output / "proton-dependencies.json").write_text(json.dumps(dict(toolchain=command("version").strip(), modules=inventory, packages=sorted(packages), telemetry_named_imports=[name for name in sorted(packages) if any(token in name.lower() for token in ("telemetry", "analytics", "sentry"))]), indent=2) + "\n")
print(f"Inventoried {len(inventory)} runtime modules; notices collected.")
