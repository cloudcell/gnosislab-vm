# GnosisLab-VM workflow

This repository packages an optional **KVM/libvirt isolated environment** for [GnosisLab](https://github.com/cloudcell/gnosislab). GnosisLab itself supplies scientific-process MCP services; this repository provisions and operates VM guests in which agents and potentially untrusted experiment code run in separately controlled zones.

## Host workflow

Requires a Linux KVM host, working `qemu:///system`, libvirt privileges, sufficient memory and disk, and sudo access. Refer to [README.md](README.md) for prerequisites.

```bash
./00-build-lab-template.sh
./01-prepare-template-for-cloning.sh
./02-create-vm-from-template.sh researcher
virsh -c qemu:///system start lab-vm-researcher
```

The numbered scripts automate the sequence and run readiness checks. Local builds and downloaded images use **different credential-handling procedures**; consult script output and [SECURITY.md](SECURITY.md). Never publish local templates with default credentials. A built template must be shut off and scrubbed before it is cloned.

## Build cache and package versions

`selfbuild/prefetch-cache.sh` prefetches required artifacts and the pinned `gnosislab` Python package. Use `--verify` to inspect cache completeness. For offline building, populate and verify the cache first, then run:

```bash
LABLOOP_OFFLINE=1 ./00-build-lab-template.sh
```

The GnosisLab package version is pinned in `create-lab-template` and may be overridden via `GNOSISLAB_VER`. Reproduce results using an explicit commit, dependency versions, ISO source/checksum, and VM image digest. Upgrading packages or images changes the trusted baseline and merits a new verification run.

## Distributing and importing images

```bash
./10-upload-template-to-hf.sh
./11-release-template.sh
```

Release scripts currently default to historical Hugging Face buckets containing `LabLoop` in their names. Those are **legacy distribution identifiers**, not current branding. Verify account identity, destination and release integrity before publication. Sealing/sysprep, matching checksums, credential locking and no secrets in the disk image are release requirements.

For an externally obtained image, inspect the publisher and provenance, verify its digest, then import:

```bash
sha256sum -c image.qcow2.sha256
./20-import-lab-vm.sh image.qcow2 researcher
```

A checksum alone does not authenticate the publisher. Do not execute unverified VM images on sensitive hosts.

## Keeping deployed guests current

```bash
./30-ensure-lab-tools.sh lab-vm-researcher
```

This updates selected deployment tooling; it is not a replacement for guest and host OS security updates, image rebuilding, or a fresh security review. Re-run the guest readiness test (`~/Desktop/check-lab-ready.sh`) after changes. Run guest security and functional batteries as part of release verification.

## Data movement

```bash
./80-ingest-lab-data.sh lab-vm-researcher ./incoming/dataset.csv research-data
# Within the guest, stage data using labloop-export as permitted by its policy.
./90-extract-lab-data.sh lab-vm-researcher ./extracted
```

The guest agent is used for **host-initiated** movement; the experiment container should not receive host filesystem mounts. Exports are untrusted content: **do not unpack or execute them on the host automatically**. See [deploy/DATA-MOVEMENT-MANUAL.md](deploy/DATA-MOVEMENT-MANUAL.md).

## Execution and isolation model

- **Host:** KVM/QEMU/libvirt VM lifecycle, import, export and templates.
- **Guest driver (`lab`):** local user interface and model clients.
- **Guest trusted (`mcp`):** GnosisLab stateful MCP services, isolated from ordinary driver file access.
- **Guest experiment (`exp`):** rootless Podman container for untrusted or generated code, with constrained ingress/egress and dedicated mounts.

The guest's legacy `labloop-exec`, `labloop-build`, `labloop-export` and `labloop-fault` commands are still live interfaces. The word `labloop` in command, directory, service, environment-variable or distribution names does not mean this project retains that public brand. Renaming these identifiers is a **separate code and migration project** requiring tests.

The security contract is [deploy/SECURITY-MANUAL.md](deploy/SECURITY-MANUAL.md). In particular, the guest admin password is **not** an isolation boundary from a human with guest administrative access. VM and container isolation reduce risk but do not eliminate it.

## Related projects

- [GnosisLab core](https://github.com/cloudcell/gnosislab)
- [GnosisLab documentation](https://loop.cloudcell.workers.dev/docs)
- [GnosisLab Python distribution](https://pypi.org/project/gnosislab/)
