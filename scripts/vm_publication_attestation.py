#!/usr/bin/env python3
"""Attest or verify a locally built VM image through GitHub OIDC.

This authenticates the publisher's statement, not the external KVM build.
The multi-gigabyte QCOW2 is never sent to GitHub.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = "cloudcell/gnosislab-vm"
WORKFLOW = "attest-vm-publication.yml"
SIGNER = f"{REPO}/.github/workflows/{WORKFLOW}"
PREDICATE = (
    "https://github.com/cloudcell/gnosislab-vm/blob/master/"
    "docs-pub/VM-PUBLICATION-ATTESTATION.md"
)
CHECKSUM = re.compile(r"^([a-f0-9]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*\.qcow2)\n?$")
COMMIT = re.compile(r"^[a-f0-9]{40}$")


class PublicationError(Exception):
    pass


def run(*args: str, stdin: str | None = None, timeout: int = 60) -> str:
    try:
        done = subprocess.run(
            list(args), input=stdin, capture_output=True,
            text=True, check=False, timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PublicationError(f"Failed to execute {args[0]}: {exc}") from exc
    if done.returncode:
        raise PublicationError(
            f"{args[0]} failed (exit {done.returncode}): {done.stderr.strip()[:1500]}"
        )
    return done.stdout


def ensure_gh_attestation_support() -> None:
    """Fail before signing or publishing if the host gh cannot verify Sigstore."""
    if not shutil.which("gh"):
        raise PublicationError(
            "GitHub CLI (gh) is missing; install or upgrade it from "
            "https://cli.github.com/ before publishing"
        )
    try:
        run("gh", "attestation", "verify", "--help", timeout=20)
    except PublicationError as exc:
        raise PublicationError(
            "GitHub CLI lacks 'gh attestation verify'. Upgrade gh from "
            "https://cli.github.com/ and confirm 'gh attestation verify --help' "
            "works. The image and checksum remain usable; nothing uploaded."
        ) from exc


def checksum_info(path: Path, expected: str | None = None) -> tuple[str, str]:
    try:
        raw = path.read_text(encoding="ascii")
    except (OSError, UnicodeError) as exc:
        raise PublicationError(f"Cannot read checksum: {path}: {exc}") from exc
    found = CHECKSUM.fullmatch(raw)
    if not found:
        raise PublicationError("Invalid checksum: expected 'SHA256  basename.qcow2'")
    digest, name = found.groups()
    if path.name != f"{name}.sha256" or (expected and name != expected):
        raise PublicationError("Checksum file name and image name do not match")
    return name, digest


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def matching_statement(
    verified: object, image: str, image_digest: str,
    sidecar_digest: str, commit: str | None = None,
) -> bool:
    if not isinstance(verified, list):
        return False
    expected = {
        (image, image_digest),
        (f"{image}.sha256", sidecar_digest),
    }
    for record in verified:
        if not isinstance(record, dict):
            continue
        stmt = record.get("verificationResult", {}).get("statement", {})
        pred = stmt.get("predicate", {})
        if (stmt.get("predicateType") != PREDICATE
            or pred.get("assertion") != "local-vm-publication"
            or pred.get("schemaVersion") != 1
            or pred.get("imageName") != image
            or pred.get("buildLocation") != "external-kvm-host"
            or pred.get("githubBuildPerformed") is not False
            or (commit and pred.get("publisherCheckoutCommit") != commit)):
            continue
        subjects = {
            (subject.get("name"), subject.get("digest", {}).get("sha256"))
            for subject in stmt.get("subject", []) if isinstance(subject, dict)
        }
        if expected <= subjects:
            return True
    return False


def verify(sidecar: Path, *, expected: str | None = None,
           commit: str | None = None) -> None:
    name, digest = checksum_info(sidecar, expected)
    ensure_gh_attestation_support()
    output = run(
        "gh", "attestation", "verify", str(sidecar.resolve()),
        "--repo", REPO, "--signer-workflow", SIGNER,
        "--predicate-type", PREDICATE, "--format", "json",
        timeout=120,
    )
    try:
        records = json.loads(output)
    except ValueError as exc:
        raise PublicationError("GitHub returned invalid attestation JSON") from exc
    if not matching_statement(records, name, digest, sha256(sidecar), commit):
        raise PublicationError("Signed publication claim does not bind image, checksum, and repository")
    print(f"Verified GitHub publication declaration for {name}: sha256:{digest}")


def request(image: Path, sidecar: Path) -> None:
    if not image.is_file():
        raise PublicationError(f"Image not found: {image}")
    name, digest = checksum_info(sidecar, image.name)
    # Preflight before dispatch. A legacy gh can successfully create
    # a signing workflow and then fail to verify its attestation.
    ensure_gh_attestation_support()
    commit = run("git", "rev-parse", "--verify", "HEAD").strip()
    if not COMMIT.fullmatch(commit):
        raise PublicationError("Not a valid publisher Git commit")
    dirty = bool(run("git", "status", "--porcelain", "--untracked-files=no").strip())
    payload = {
        "ref": "master",
        "return_run_details": True,
        "inputs": {
            "image_name": name,
            "image_sha256": digest,
            "checksum_sha256": sha256(sidecar),
            "publisher_commit": commit,
            "publisher_dirty": str(dirty).lower(),
        },
    }
    result = run(
        "gh", "api", "--method", "POST",
        f"repos/{REPO}/actions/workflows/{WORKFLOW}/dispatches",
        "-H", "X-GitHub-Api-Version: 2022-11-28",
        "--input", "-", stdin=json.dumps(payload),
    )
    try:
        run_id = json.loads(result)["workflow_run_id"]
    except (ValueError, KeyError, TypeError) as exc:
        raise PublicationError("Dispatch did not return run ID (upgrade gh)") from exc
    if not isinstance(run_id, int) or run_id < 1:
        raise PublicationError("Invalid workflow run ID")
    print(f"Attestation workflow: https://github.com/{REPO}/actions/runs/{run_id}", flush=True)
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        status = json.loads(run(
            "gh", "run", "view", str(run_id),
            "--repo", REPO, "--json", "status,conclusion",
        ))
        if status.get("status") == "completed":
            if status.get("conclusion") != "success":
                raise PublicationError(f"Attestation job failed: {status.get('conclusion')}")
            verify(sidecar, expected=name, commit=commit)
            return
        time.sleep(5)
    raise PublicationError("Attestation job did not finish within 15 minutes")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    a = sub.add_parser("request")
    a.add_argument("image", type=Path)
    a.add_argument("checksum", type=Path)
    b = sub.add_parser("verify")
    b.add_argument("checksum", type=Path)
    b.add_argument("--image-name")
    opts = parser.parse_args()
    try:
        if opts.command == "request":
            request(opts.image, opts.checksum)
        else:
            verify(opts.checksum, expected=opts.image_name)
    except (PublicationError, OSError, ValueError) as exc:
        print(f"VM publication attestation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
