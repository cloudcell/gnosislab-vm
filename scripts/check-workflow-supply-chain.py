#!/usr/bin/env python3
"""Fail CI for mutable or unusually privileged GitHub Actions workflows.

Deliberately self-contained: no PyPI install or third-party parser is needed
to validate remote action references before any dependency-review action runs.
This is a targeted policy check, not a full YAML or security analysis engine.
"""
from __future__ import annotations

import re
from pathlib import Path

WORKFLOWS = Path(".github/workflows")
USES = re.compile(r"""^\s*(?:-\s*)?uses:\s*['"]?([^'"#\s]+)""")
REMOTE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[^@\s]+)?@([a-f0-9]{40})$")
DOCKER = re.compile(r"^docker://[^@\s]+@sha256:[a-f0-9]{64}$")
CHECKOUT = re.compile(r"^actions/checkout@[a-f0-9]{40}$")
PERSIST_FALSE = re.compile(r"^\s*persist-credentials:\s*false(?:\s*#.*)?$")
DANGEROUS_TRIGGER = re.compile(r"^\s*(pull_request_target|workflow_run)\s*:")
DANGEROUS_PERMISSION = re.compile(r"^\s*permissions:\s*write-all(?:\s*#.*)?$")
PERSIST_TRUE = re.compile(r"^\s*persist-credentials:\s*true(?:\s*#.*)?$")


def main() -> int:
    files = sorted((*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")))
    failures: list[str] = []
    remote_actions = 0

    if not files:
        failures.append("No GitHub Actions workflow files were found.")

    for path in files:
        lines = path.read_text(encoding="utf-8").splitlines()
        if not any(re.match(r"^permissions:\s*(?:#.*)?$", line) for line in lines):
            failures.append(f"{path}: explicit top-level permissions are required")

        for number, line in enumerate(lines, 1):
            stripped = line.lstrip()
            if not stripped or stripped.startswith("#"):
                continue
            if DANGEROUS_TRIGGER.match(line):
                failures.append(f"{path}:{number}: privileged trigger needs separate review")
            if DANGEROUS_PERMISSION.match(line):
                failures.append(f"{path}:{number}: write-all is forbidden")
            if PERSIST_TRUE.match(line):
                failures.append(f"{path}:{number}: checkout credentials must not persist")
            match = USES.match(line)
            if not match:
                continue
            ref = match.group(1)
            if ref.startswith("./"):
                # Actions in this repository are allowed as local references.
                continue
            if ref.startswith("docker://"):
                if not DOCKER.fullmatch(ref):
                    failures.append(f"{path}:{number}: container action must be digest-pinned: {ref}")
                continue
            if not REMOTE.fullmatch(ref):
                failures.append(f"{path}:{number}: action must use full 40-character commit SHA: {ref}")
                continue
            remote_actions += 1
            if CHECKOUT.fullmatch(ref):
                # A checkout must not expose its credentials to later build steps.
                block = lines[number:number + 8]
                if not any(PERSIST_FALSE.match(next_line) for next_line in block):
                    failures.append(f"{path}:{number}: checkout must set persist-credentials: false")

    if remote_actions == 0:
        failures.append("No remote actions found; check that workflow parsing still works.")

    if failures:
        print("Supply-chain workflow policy FAILED:")
        for item in failures:
            print(f"  - {item}")
        return 1

    print(f"Supply-chain workflow policy passed: {len(files)} workflow(s), "
          f"{remote_actions} SHA-pinned remote action reference(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
