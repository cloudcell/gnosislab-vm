# Verifiable VM publication (Feature 6)

GnosisLab-VM images are **built on the publisher's local KVM/libvirt machine**, not GitHub runners. The automated GitHub attestation is a cryptographically signed **publication declaration** associating a VM image digest with the Cloudcell GitHub repository. It **does not** independently prove the host ran an unmodified build, assert reproducibility, or meet SLSA Build Level 3.

## Signed provenance manifest

Each newly published image has three companion records:

- `<image>.qcow2`: the actual compressed VM disk
- `<image>.qcow2.sha256`: its SHA-256 checksum
- `<image>.qcow2.provenance.json`: readable structured publication metadata

The JSON includes GnosisLab version, its evidence source, the image and
checksum digests, the publisher checkout commit, the template builder commit
(when a successfully completed build recorded it), and the identity of
the GitHub OIDC/Sigstore signing workflow. The repository is the signer
identity; the workflow authenticates **publication claims**, not an
independently reproduced KVM build.

**The JSON itself is a third subject in GitHub's signed attestation.**
Changing its version, source commit or SHA-256 after signing breaks
cryptographic verification. Old attestations with only two subjects do
not validate the new manifest.

New template builds save `dist/<template>.build-info.json`, containing
the resolved GnosisLab package version and the source commit used at the
end of a successful build. The publishing script takes that value,
preserving the distinction between `templateBuildCommit` and
`publisherCheckoutCommit`. If the build record is missing, official
publication stops unless the publisher explicitly supplies
`GNOSISLAB_VER=X.Y.Z`; such versions are labelled `publisher-declared`.

To validate all three files after downloading:

```bash
sha256sum -c image.qcow2.sha256
python3 scripts/vm_publication_attestation.py verify image.qcow2.sha256 \
  --provenance image.qcow2.provenance.json
```

### Backfill the already released October 14 image

The file `lab-template-20261014T0456Z-20261014T0539Z.qcow2` was
published before this feature. **Do not download, reseal or reupload the
7.18 GB disk.** Its existing local copy, checksum and release bucket
are sufficient. On the trusted physical host, after merging this feature:

```bash
git switch master && git pull --ff-only
IMAGE=dist/lab-template-20261014T0456Z-20261014T0539Z.qcow2
sha256sum -c "$IMAGE.sha256"
python3 scripts/vm_publication_attestation.py provenance-create \
  "$IMAGE.sha256" --gnosislab-version 0.1.45
python3 scripts/vm_publication_attestation.py request \
  "$IMAGE" "$IMAGE.sha256" --provenance "$IMAGE.provenance.json"
hf buckets cp "$IMAGE.provenance.json" \
  "hf://buckets/cloudcell/LabLoop/$(basename "$IMAGE").provenance.json"
```

The historical version is explicitly *publisher-declared*, because
the original completed build did not record version metadata for this
feature. The new signed record binds the exact existing image digest
and the new JSON, without modifying the previously released QCOW2.

**There is no need to re-upload the existing QCOW2 or checksum.**
## Automated official publication

After the existing local build, the standard pipeline is:

1. `./10-upload-template-to-hf.sh` prompts for the usual publication confirmation, seals the VM, converts to a final QCOW2, creates and locally verifies `<image>.qcow2.sha256`.
2. The publisher requests a `workflow_dispatch` on `.github/workflows/attest-vm-publication.yml` with the exact image SHA-256, checksum-file SHA-256, local publishing Git commit and its dirty flag. **No VM bytes are sent to GitHub.**
3. GitHub's `actions/attest` obtains a short-lived OIDC-based Sigstore certificate and signs a custom in-toto predicate. Its subjects are the VM digest, checksum sidecar digest and signed JSON provenance digest (when supplied). GitHub stores the attestation on this repository.
4. The local uploader watches the **specific returned workflow run ID**, verifies its successful completion, independently runs `gh attestation verify` against the local checksum file with the repository, signer workflow and predicate constrained, and compares both subject hashes and declared commit. If any check fails, the image is **not uploaded**.
5. `./11-release-template.sh` downloads **only the checksum and provenance sidecars** from the private HF trials bucket, verifies its signed declaration, including the provenance digest, and associated image digest, then copies the VM, checksum and signed JSON provenance to the public release bucket. The official destination always requires verification and refuses unsigned releases.

Prerequisites for an official publisher:

- `gh` CLI (authenticate once with `gh auth login`) with permission to dispatch workflows in `cloudcell/gnosislab-vm`, and Hugging Face `hf` CLI access to the configured buckets.
- GitHub Actions and artifact attestations enabled for the public repository.
- Python 3 on the publisher.
- No long-lived artifact signing key. A GitHub authorization token is still required for dispatch, but it is not a signing key and is **not** shared with independent builders.

## Recover an already-built image after a GitHub CLI error

If publication stopped after image compression and checksum verification,
the QCOW2 and its `.sha256` sidecar remain in `dist/`. Do **not**
rebuild or reseal the VM. The GitHub signing workflow may already have
succeeded although an old local `gh` cannot verify its attestation.

1. Upgrade GitHub CLI from https://cli.github.com/ and check:
   `gh attestation verify --help`.
2. Verify the previously generated image and checksum locally.
3. Resume the upload from exactly those existing files:

```bash
bash scripts/resume-vm-trial-upload.sh \
  dist/lab-template-20261014T0456Z-20261014T0520Z.qcow2
```

The helper checks both the local SHA-256 checksum and the previously
signed GitHub publication statement before asking to upload. It does
not create a new signature, reseal a template or recompress an image.

If the earlier attestation workflow did not succeed, sign the existing
QCOW2 and sidecar without rebuilding:

```bash
python3 scripts/vm_publication_attestation.py request \
  dist/your-image.qcow2 dist/your-image.qcow2.sha256
```

Then rerun the resume helper. Do not use `VM_ATTESTATION=skip` to
publish an official Cloudcell image; that bypasses signing checks.
\n## Independent and community builders

**Local VM creation, cloning, export and import need no Cloudcell GitHub access.**

To publish an image to a bucket you control without a Cloudcell-signed attestation:

```bash
VM_ATTESTATION=skip ./10-upload-template-to-hf.sh lab-template-example hf://buckets/YOUR_ACCOUNT/trials
VM_ATTESTATION=skip SRC_BUCKET=hf://buckets/YOUR_ACCOUNT/trials \
  DST_BUCKET=hf://buckets/YOUR_ACCOUNT/releases \
  ./11-release-template.sh
```

This still generates and requires the SHA-256 sidecar, but prints an **unattested** warning. It does not attest to or assert Cloudcell provenance. The official `hf://buckets/cloudcell/LabLoop` destination cannot use `VM_ATTESTATION=skip`.

If `VM_ATTESTATION` is omitted, the publication scripts use `required` and fail closed when GitHub attestation is unavailable. `SKIP_SEAL=1` remains a separate existing setting and should only be used when the image has already been sealed safely.

## Verification by recipients

After downloading `image.qcow2`, `image.qcow2.sha256` and `image.qcow2.provenance.json`:

```bash
sha256sum -c image.qcow2.sha256
python3 scripts/vm_publication_attestation.py verify image.qcow2.sha256 \
  --provenance image.qcow2.provenance.json
```

The first command verifies the downloaded image contents. The second independently verifies GitHub's signature on the checksum file and confirms the signed declaration names the same VM digest and the unchanged provenance JSON. The helper checks the expected signing repository, `.github/workflows/attest-vm-publication.yml` workflow, predicate URI and both subjects.

The signed custom predicate URI is this document's public URL. All predicate fields supplied by the external publisher are **claims**, not verified build-environment facts. Github's signature authenticates which workflow made the claim and which subject digests it signed. It cannot guarantee the source checkout built the image, the absence of malware, or completeness of dependencies. Trust the publisher's integrity and review the build and VM configuration separately.

**Scope note:** QCOW2 is currently the signed artifact. Independently converted VMDK/OVA outputs have SHA-256 sidecars but are not automatically attested under this workflow.
