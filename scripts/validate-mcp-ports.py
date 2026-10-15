#!/usr/bin/env python3
"""Validate trusted GnosisLab ports.env before shell sourcing / quadlet render."""
import re
import sys
from pathlib import Path

REQUIRED = {"ML_AGORA_PORT", "ML_ARETE_PORT", "ML_ZETESIS_PORT",
            "ML_EPISTEME_PORT", "ML_ANAMNESIS_PORT"}
KEY = re.compile(r"ML_[A-Z_]+_PORT")
ENTRY = re.compile(r"(ML_[A-Z_]+_PORT)=([0-9]{2,5})")

def validate(path):
    found = {}
    for number, original in enumerate(Path(path).read_text().splitlines(), 1):
        line = original.strip()
        if not line or line.startswith("#"):
            continue
        match = ENTRY.fullmatch(line)
        if not match:
            raise ValueError(f"line {number}: non-port or unsafe assignment")
        key, value = match.groups()
        port = int(value)
        if not KEY.fullmatch(key) or not 1024 <= port <= 65535:
            raise ValueError(f"line {number}: invalid port")
        if key in found:
            raise ValueError(f"line {number}: duplicate {key}")
        found[key] = port
    missing = REQUIRED - found.keys()
    if missing:
        raise ValueError("missing required port(s): " + ", ".join(sorted(missing)))
    if len(set(found.values())) != len(found):
        raise ValueError("duplicate port values")
    return found

if __name__ == "__main__":
    try:
        validate(sys.argv[1])
    except (IndexError, OSError, ValueError) as exc:
        print(f"invalid MCP ports.env: {exc}", file=sys.stderr)
        sys.exit(1)
