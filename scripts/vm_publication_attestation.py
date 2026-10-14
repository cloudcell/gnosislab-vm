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



PROVENANCE_FORMAT = "gnosislab-vm-publication-provenance"
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[a-zA-Z0-9.+-]+)?$")
WORKFLOW_URL = f"https://github.com/{REPO}/actions/workflows/{WORKFLOW}"


def provenance_path(sidecar: Path) -> Path:
    if not sidecar.name.endswith(".qcow2.sha256"):
        raise PublicationError("Provenance requires a QCOW2 checksum sidecar")
    return sidecar.with_name(sidecar.name.removesuffix(".sha256") + ".provenance.json")


def provenance_data(sidecar: Path, manifest: Path, *,
                    commit: str | None = None,
                    dirty: bool | None = None) -> dict:
    """Fail closed if an unsigned field disagrees with the local or signed data."""
    name, digest = checksum_info(sidecar)
    if manifest.name != provenance_path(sidecar).name:
        raise PublicationError("Provenance filename does not match image")
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as exc:
        raise PublicationError(f"Invalid provenance JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise PublicationError("Provenance must be a JSON object")
    image = data.get("image", {})
    software = data.get("software", {})
    source = data.get("source", {})
    signature = data.get("signature", {})
    if not all(isinstance(x, dict) for x in (image, software, source, signature)):
        raise PublicationError("Invalid provenance fields")
    if (data.get("schemaVersion") != 1
        or data.get("kind") != PROVENANCE_FORMAT
        or image.get("name") != name
        or image.get("sha256") != digest
        or image.get("checksumName") != sidecar.name
        or image.get("checksumSha256") != sha256(sidecar)
        or not isinstance(software.get("gnosislabVersion"), str)
        or not VERSION.fullmatch(software["gnosislabVersion"])
        or software.get("versionEvidence") not in
            ("builder-recorded", "publisher-declared")
        or source.get("repository") != f"https://github.com/{REPO}"
        or not COMMIT.fullmatch(str(source.get("publisherCheckoutCommit", "")))
        or not isinstance(source.get("publisherTrackedFilesDirty"), bool)
        or (source.get("templateBuildCommit") is not None and
            not COMMIT.fullmatch(str(source["templateBuildCommit"])))
        or signature.get("repository") != REPO
        or signature.get("signerWorkflow") != SIGNER
        or signature.get("workflowUrl") != WORKFLOW_URL
        or signature.get("attestationLookupUrl") != (
            f"https://api.github.com/repos/{REPO}/attestations/sha256:{digest}"
        )
        or signature.get("predicateType") != PREDICATE
        or signature.get("mechanism") != "GitHub OIDC / Sigstore"
        or signature.get("declarationOnly") is not True
        or signature.get("independentBuildVerification") is not False
        or (commit and source.get("publisherCheckoutCommit") != commit)
        or (dirty is not None and
            source.get("publisherTrackedFilesDirty") is not dirty)):
        raise PublicationError("Provenance metadata does not match signed publication policy")
    return data


def create_provenance(sidecar: Path, *, version: str | None = None,
                      build_info: Path | None = None) -> Path:
    name, digest = checksum_info(sidecar)
    if build_info is not None:
        try:
            info = json.loads(build_info.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError) as exc:
            raise PublicationError(f"Invalid template build-info: {exc}") from exc
        if (not isinstance(info, dict)
            or info.get("schemaVersion") != 1
            or info.get("templateName") != name.rsplit("-", 1)[0]):
            # The filename also includes the export UTC timestamp.
            raise PublicationError("Build-info does not match this VM template")
        recorded = info.get("gnosislabVersion")
        if version is not None and version != recorded:
            raise PublicationError("Requested GnosisLab version disagrees with build record")
        version = recorded
        builder_commit = info.get("vmBuilderCommit")
        if not isinstance(builder_commit, str) or not COMMIT.fullmatch(builder_commit):
            raise PublicationError("Invalid builder commit in build-info")
        source = "builder-recorded"
    else:
        builder_commit = None
        source = "publisher-declared"
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise PublicationError(
            "GnosisLab version unknown; pass --gnosislab-version "
            "X.Y.Z or --build-info from a completed template build"
        )
    commit = run("git", "rev-parse", "--verify", "HEAD").strip()
    if not COMMIT.fullmatch(commit):
        raise PublicationError("Not a valid publisher Git commit")
    dirty = bool(run("git", "status", "--porcelain", "--untracked-files=no").strip())
    record = {
        "schemaVersion": 1,
        "kind": PROVENANCE_FORMAT,
        "image": {
            "name": name, "sha256": digest,
            "checksumName": sidecar.name,
            "checksumSha256": sha256(sidecar),
        },
        "software": {
            "gnosislabVersion": version, "versionEvidence": source,
        },
        "source": {
            "repository": f"https://github.com/{REPO}",
            "publisherCheckoutCommit": commit,
            "publisherTrackedFilesDirty": dirty,
            "templateBuildCommit": builder_commit,
        },
        "signature": {
            "repository": REPO,
            "signerWorkflow": SIGNER,
            "workflowUrl": WORKFLOW_URL,
            "attestationLookupUrl": (
                f"https://api.github.com/repos/{REPO}/attestations/sha256:{digest}"
            ),
            "predicateType": PREDICATE,
            "mechanism": "GitHub OIDC / Sigstore",
            "declarationOnly": True,
            "independentBuildVerification": False,
        },
    }
    output = provenance_path(sidecar)
    serialized = json.dumps(record, indent=2, sort_keys=True) + "\n"
    if output.exists():
        if output.read_text(encoding="utf-8") != serialized:
            raise PublicationError(
                f"Provenance already exists with different metadata: {output}"
            )
    else:
        output.write_text(serialized, encoding="utf-8")
    provenance_data(sidecar, output, commit=commit, dirty=dirty)
    print(f"Provenance manifest: {output}")
    return output


def matching_statement(
    verified: object, image: str, image_digest: str,
    sidecar_digest: str, commit: str | None = None,
    manifest_digest: str | None = None,
) -> bool:
    if not isinstance(verified, list):
        return False
    expected = {
        (image, image_digest),
        (f"{image}.sha256", sidecar_digest),
    }
    if manifest_digest is not None:
        expected.add((f"{image}.provenance.json", manifest_digest))
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
           commit: str | None = None, provenance: Path | None = None) -> None:
    name, digest = checksum_info(sidecar, expected)
    manifest = provenance_data(sidecar, provenance, commit=commit) if provenance else None
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
    if not matching_statement(
        records, name, digest, sha256(sidecar), commit,
        sha256(provenance) if manifest else None,
    ):
        raise PublicationError("Signed publication claim does not bind image, checksum, and repository")
    print(f"Verified GitHub publication declaration for {name}: sha256:{digest}")


def request(image: Path, sidecar: Path, provenance: Path | None = None) -> None:
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
    if provenance is not None:
        provenance_data(sidecar, provenance, commit=commit, dirty=dirty)
    payload = {
        "ref": "master",
        "return_run_details": True,
        "inputs": {
            "image_name": name,
            "image_sha256": digest,
            "checksum_sha256": sha256(sidecar),
            "publisher_commit": commit,
            "publisher_dirty": str(dirty).lower(),
            "provenance_sha256": sha256(provenance) if provenance else "",
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
            verify(sidecar, expected=name, commit=commit, provenance=provenance)
            return
        time.sleep(5)
    raise PublicationError("Attestation job did not finish within 15 minutes")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    a = sub.add_parser("request")
    a.add_argument("image", type=Path)
    a.add_argument("checksum", type=Path)
    a.add_argument("--provenance", type=Path)
    b = sub.add_parser("verify")
    b.add_argument("checksum", type=Path)
    b.add_argument("--image-name")
    b.add_argument("--provenance", type=Path)
    c = sub.add_parser("provenance-create")
    c.add_argument("checksum", type=Path)
    c.add_argument("--gnosislab-version")
    c.add_argument("--build-info", type=Path)
    d = sub.add_parser("provenance-check")
    d.add_argument("checksum", type=Path)
    d.add_argument("--provenance", type=Path, required=True)
    opts = parser.parse_args()
    try:
        if opts.command == "request":
            request(opts.image, opts.checksum, provenance=opts.provenance)
        elif opts.command == "verify":
            verify(opts.checksum, expected=opts.image_name, provenance=opts.provenance)
        elif opts.command == "provenance-create":
            create_provenance(
                opts.checksum, version=opts.gnosislab_version,
                build_info=opts.build_info,
            )
        else:
            provenance_data(opts.checksum, opts.provenance)
            print(f"Provenance manifest consistent: {opts.provenance}")
    except (PublicationError, OSError, ValueError) as exc:
        print(f"VM publication attestation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
