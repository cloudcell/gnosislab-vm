# Feature 7B: Trial-process isolation (release-gated)

**Status:** VM integration prepared, but DO NOT merge or deploy until the
core GnosisLab executor patch is released, pinned, and validated in a
disposable VM clone. The current VM pin is `gnosislab==0.1.42` and does
not support this protection.

## Boundary

Episteme launches potentially hostile trials inside the MCP container.
The trusted container also holds scientific SQLite databases, ingest
credentials, and logs under `/state`.

The core GnosisLab change proposed in
[cloudcell/gnosislab#6](https://github.com/cloudcell/gnosislab/pull/6)
introduces an opt-in `ML_EPISTEME_TRIAL_ISOLATION=enforced` mode:

- Requires Bubblewrap full mode, with no `sandbox=none` downgrade.
- Hides `/state` from the trial process with a private tmpfs and
  exposes only the active trial's artifact directory as writable.
- Separates trial network, PID and IPC namespaces; removes trial
  capabilities. Trial code cannot use public networks or localhost MCP.
- Refuses explicit mounts through trusted state or its path aliases.

The VM's trusted MCP entrypoint forces this mode, and checks the core
executor's effective sandbox arguments BEFORE starting any MCP service.
An unpatched package fails **closed**, rather than silently launching an
unisolated Episteme server.

## Release dependency and operational trade-off

1. Merge and publish a properly versioned GnosisLab release with the
   isolation patch, after upstream tests pass.
2. Update the GnosisLab version pinned by `create-lab-template`.
3. Rebuild the MCP container image (not necessarily the whole golden VM).
4. Exercise real trial launch, artifact capture, denial of access to
   `/state` and network access, and legitimate data processing in a
   disposable KVM clone.
5. Only then merge/roll out this VM guard.

A trial requiring external network access will **fail to access the network**
in the enforced mode. Download datasets and models separately into approved
data locations before running trials. A separate, explicitly approved
network policy could be designed later if the workflow needs selected egress.

**This is not a KVM-level sandbox.** It is a defense-in-depth Bubblewrap
namespace boundary within a trusted service container. It must be tested
with the installed rootless Podman seccomp and capability configuration.

## Acceptance criteria

- `LocalExecutor(sandbox="full")` initializes successfully only if
  protected mode is implemented and Bubblewrap is available.
- Trial code cannot read `/state/*.db`, `/state/ingest.env`, sibling
  trials' artifacts, or the MCP process environment.
- Trial code cannot connect to `127.0.0.1:<MCP port>` or public internet.
- Legitimate trials can still write only to their own artifact directory
  and upload/capture trial evidence.
- Attempts to rebind trusted files through config/data paths fail closed.
- Existing trusted services retain their normal functions.
