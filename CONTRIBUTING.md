# Contributing to GnosisLab-VM

Thanks for considering contributions to **GnosisLab-VM**, the optional KVM/libvirt isolation environment for [GnosisLab](https://github.com/cloudcell/gnosislab). The project is alpha software. Prefer focused changes with reproducible tests and documented security effects.

Before opening a PR, check [issues](https://github.com/cloudcell/gnosislab-vm/issues), separate refactoring from behavior changes, and update documentation when modifying user-visible behavior.

## Local setup

```bash
git clone https://github.com/cloudcell/gnosislab-vm.git
cd gnosislab-vm
git config --local core.hooksPath .githooks
```

The tracked pre-commit hook checks common private-information leaks. It is a guardrail, not a substitute for careful review. Run `.githooks/pre-commit --all` before submitting; use `--strict` for stricter checks.

## Validation

For shell changes, run `bash -n` on changed Bash scripts and `shellcheck` where available. The GitHub `repository-hygiene` workflow checks syntax and project metadata, but **does not prove runtime security**. Changes involving networking, privileged wrappers, mounts, Podman, image sealing, or VM creation require the applicable in-guest functional and security batteries, plus manual threat-model review. Record the environment, test commands, and actual results in the PR.

Never run untrusted guest code on your primary host to test it. Do not attach real secrets or sensitive datasets to issues, PRs, CI artifacts, or test images.

## Compatibility

Use **GnosisLab-VM** for this repository, **GnosisLab** for the scientific runtime, and **LabLoop** only when documenting historical identity or existing compatible command names/paths. Do not rename `LABLOOP_*`, `labloop-*`, libvirt domain conventions, or image buckets as a documentation-only change: migrations need explicit compatibility decisions and tests.

## Licensing and contributions

The project uses [Apache-2.0](LICENSE). Follow the contribution sign-off and possible CLA procedures in [legal/CONTRIBUTOR-SIGNOFFS.md](legal/CONTRIBUTOR-SIGNOFFS.md) and [legal/CONTRIBUTOR-CLA.md](legal/CONTRIBUTOR-CLA.md). See [legal/TRADEMARKS.md](legal/TRADEMARKS.md) for marks.

## Responsible disclosure

Security vulnerabilities must **not** be reported through public issues. Follow [SECURITY.md](SECURITY.md).
