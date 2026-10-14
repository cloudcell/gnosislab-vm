# Verifiable VM publication (Feature 6)

GnosisLab-VM images are **built on the publisher's local KVM/libvirt machine**, not GitHub runners. The automated GitHub attestation is a cryptographically signed **publication declaration** associating a VM image digest with the Cloudcell GitHub repository. It **does not** independently prove the host ran an unmodified build, assert reproducibility, or meet SLSA Build Level 3.

## Automated official publication

After the existing local build, the standard pipeline is:

1. `./10-upload-template-to-hf.sh` prompts for the usual publication confirmation, seals the VM, converts to a final QCOW2, creates and locally verifies `<image>.qcow2.sha256`.
2. The publisher requests a `workflow_dispatch` on `.github/workflows/attest-vm-publication.yml` with the exact image SHA-256, checksum-file SHA-256, local publishing Git commit and its dirty flag. **No VM bytes are sent to GitHub.**
3. GitHub's `actions/attest` obtains a short-lived OIDC-based Sigstore certificate and signs a custom in-toto predicate. Its subjects are the VM digest **and** checksum sidecar digest. GitHub stores the attestation on this repository.
4. The local uploader watches the **specific returned workflow run ID**, verifies its successful completion, independently runs `gh attestation verify` against the local checksum file with the repository, signer workflow and predicate constrained, and compares both subject hashes and declared commit. If any check fails, the image is **not uploaded**.
5. `./11-release-template.sh` downloads **only the small checksum sidecar** from the private HF trials bucket, verifies its signed declaration and associated image digest, then copies the VM and checksum to the public release bucket. The official destination always requires verification and refuses unsigned releases.

Prerequisites for an official publisher:

- `gh` CLI (authenticate once with `gh auth login`) with permission to dispatch workflows in `cloudcell/gnosislab-vm`, and Hugging Face `hf` CLI access to the configured buckets.
- GitHub Actions and artifact attestations enabled for the public repository.
- Python 3 on the publisher.
- No long-lived artifact signing key. A GitHub authorization token is still required for dispatch, but it is not a signing key and is **not** shared with independent builders.

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

After downloading `image.qcow2` and `image.qcow2.sha256`:

```bash
sha256sum -c image.qcow2.sha256
python3 scripts/vm_publication_attestation.py verify image.qcow2.sha256
```

The first command verifies the downloaded image contents. The second independently verifies GitHub's signature on the checksum file and confirms the signed declaration names the same VM digest. The helper checks the expected signing repository, `.github/workflows/attest-vm-publication.yml` workflow, predicate URI and both subjects.

The signed custom predicate URI is this document's public URL. All predicate fields supplied by the external publisher are **claims**, not verified build-environment facts. Github's signature authenticates which workflow made the claim and which subject digests it signed. It cannot guarantee the source checkout built the image, the absence of malware, or completeness of dependencies. Trust the publisher's integrity and review the build and VM configuration separately.

**Scope note:** QCOW2 is currently the signed artifact. Independently converted VMDK/OVA outputs have SHA-256 sidecars but are not automatically attested under this workflow.
