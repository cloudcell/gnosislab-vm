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
`publisherCheckoutCommit`. If the build record is missing, publication stops unless the publisher explicitly supplies
`GNOSISLAB_VER=X.Y.Z`; such versions are labelled `publisher-declared`.

To validate all three files after downloading:

```bash
sha256sum -c image.qcow2.sha256
python3 scripts/vm_publication_attestation.py verify image.qcow2.sha256 \
  --provenance image.qcow2.provenance.json
```

### Backfill an already released image using script 11

The October 14 QCOW2 was published before signed provenance manifests
were introduced. It can be backfilled without rebuilding or uploading
its 7.18 GB disk again. After updating the repository, use the same
standard `11-release-template.sh` command with `--backfill`:

```bash
git switch master && git pull --ff-only
GNOSISLAB_VER=0.1.45 ./11-release-template.sh --backfill \
  lab-template-20261014T0456Z-20261014T0539Z.qcow2
```

Script 11 locates the existing QCOW2 and checksum in `dist/`, verifies
their integrity, compares the checksum against the already published
checksum in the official bucket, creates provenance if missing, requests
and verifies the GitHub signature, then uploads **only** the JSON file.
The historical GnosisLab version is labelled `publisher-declared`,
because its older build predated automated build-info recording.
The existing VM, QCOW2 and checksum are not modified or uploaded again.

To resume a candidate upload that stopped after sealing or signing,
use **only script 10** with its `--existing` option:

```bash
GNOSISLAB_VER=0.1.45 ./10-upload-template-to-hf.sh --existing \
  dist/your-already-sealed-image.qcow2
```

Script 10 checks the existing checksum, creates and signs provenance
(or verifies an existing signature) and uploads the three files. It
never reboots, reseals or recompresses the existing QCOW2 in this mode.
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

If the upload stopped after compression, fix the host GitHub CLI
(check `gh attestation verify --help`), then use
`./10-upload-template-to-hf.sh --existing dist/<image>.qcow2`.
This standard command verifies and reuses the existing image; it does
not reseal the template, regenerate the QCOW2 or require an extra
recovery executable. For an image that is **already public**, use
`./11-release-template.sh --backfill <image>.qcow2` instead.
## Independent and community builders

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
