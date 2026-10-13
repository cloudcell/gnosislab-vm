#!/usr/bin/env bash
# Requires gh CLI with repository administration privileges.
set -euo pipefail
repo='cloudcell/gnosislab-vm'
command -v gh >/dev/null || { echo 'Install GitHub CLI (gh) first' >&2; exit 1; }
gh auth status >/dev/null
# PATCH repository description + homepage.
gh api --method PATCH "repos/$repo" \
  -f description='Virtualized GnosisLab research environment with KVM isolation, protected scientific services, and sandboxed experiment execution.' \
  -f homepage='https://loop.cloudcell.workers.dev/docs' >/dev/null
# PUT complete topic set.
gh api --method PUT "repos/$repo/topics" \
  --input <(printf '%s\n' '{"names":["gnosislab","ai-for-science","scientific-method","research-automation","reproducibility","virtualization","virtual-machine","kvm","qemu","libvirt","sandbox","security","podman","model-context-protocol","ai-agents"]}') >/dev/null
echo "Metadata updated for $repo"
