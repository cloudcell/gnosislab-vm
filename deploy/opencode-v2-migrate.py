#!/usr/bin/env python3
"""Migrate GnosisLab-managed OpenCode V1 configuration to V2 in place.

Run as lab. Preserve custom keys; back up every changed file.
"""
import json
import pathlib
import shutil
import sys

ROOT = pathlib.Path.home() / ".config/opencode"

def atomic_write(path, data):
    tmp = path.with_name(path.name + ".v2-new")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.chmod(0o600)
    tmp.replace(path)

def migrate(path):
    if not path.exists():
        return
    try:
        config = json.loads(path.read_text())
    except json.JSONDecodeError:
        print(f"SKIP: custom JSONC in {path}; manual migration needed", file=sys.stderr)
        return
    changed = False
    if "provider" in config:
        legacy = config.pop("provider")
        dest = config.setdefault("providers", {})
        for key, value in legacy.items():
            if key in dest:
                continue
            if "npm" in value:
                value["package"] = ("aisdk:" + value.pop("npm")) if not value["npm"].startswith("aisdk:") else value.pop("npm")
            if "options" in value:
                value["settings"] = value.pop("options")
            dest[key] = value
        changed = True
    if "update" in config:
        # V2 uses autoupdate, not update.
        config.pop("update")
        changed = True
    if changed:
        backup = path.with_name(path.name + ".v1-backup")
        if not backup.exists():
            shutil.copy2(path, backup)
        atomic_write(path, config)
        print(f"Migrated {path}; backup {backup}")

if __name__ == "__main__":
    for name in ("opencode.json", "opencode.jsonc"):
        migrate(ROOT / name)
