# GitHub repository settings (administrator checklist)

These GitHub settings cannot be controlled by Markdown alone. Apply them in the repository **About** panel, **Settings**, or using `scripts/set-repo-metadata.sh` with an authenticated GitHub CLI.

**Description** (GitHub's 350-character limit):

> Virtualized GnosisLab research environment with KVM isolation, protected scientific services, and sandboxed experiment execution.

**Website:** https://loop.cloudcell.workers.dev/docs

**Topics:** `gnosislab`, `ai-for-science`, `scientific-method`, `research-automation`, `reproducibility`, `virtualization`, `virtual-machine`, `kvm`, `qemu`, `libvirt`, `sandbox`, `security`, `podman`, `model-context-protocol`, `ai-agents`.

**Recommended Settings:** Enable GitHub Issues, vulnerability reporting/private advisory channels, Dependabot alerts (and security updates when appropriate), and secret scanning/push protection if available. Add branch protection/rulesets requiring the `repository-hygiene` workflow to pass before merges, then require PR review if collaborators are active. Prefer squash merges for a clean public history. Disable unnecessary wiki/projects if unused. Maintain the existing Apache-2.0 license.

**Terminology:** GnosisLab is the scientific runtime at https://github.com/cloudcell/gnosislab. GnosisLab-VM is this optional virtualized, isolated deployment. `LabLoop` is a historical name. Keep existing operational identifiers until separately migrated and tested. Do not characterize VM isolation as an absolute protection guarantee.
