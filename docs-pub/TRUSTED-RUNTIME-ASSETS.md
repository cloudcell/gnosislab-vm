# Feature 7A: Trusted MCP runtime asset isolation

This hardening closes the agent-to-trusted-code execution path identified in the
14 October 2026 source audit. The driver account `lab` may modify the VM
workspace, but it cannot directly write the files the `mcp` service loads
for its startup supervisor or seccomp policy.

## Protected paths

| File | Guest owner/mode | Use |
| --- | --- | --- |
| `/usr/local/libexec/labloop-mcp-entrypoint` | root:root, 0755 | Bind-mounted read-only over `/usr/local/bin/labloop-mcp` in modern packaged MCP images |
| `/etc/labloop/seccomp-labloop.json` | root:root, 0644 | Rootless Podman's host-side `SeccompProfile` |

Both sources are transferred **from the host checkout through QEMU guest agent**
and staged under root-controlled directories. Neither is copied from the
agent-writable in-guest workspace. Supervisor updates still require **no full VM
image rebuild**.

The `lab-cnt-mcp.container` template is rendered before installation. It
contains no unexpanded `@MCP_*` placeholders after a successful render.
Its Podman definition remains owned by `mcp` in `~mcp/.config/containers/systemd`;
the driver cannot modify that directory without additional privileges.

## New VM templates

`create-lab-template` installs both protected files before starting the
trusted container and renders the protected supervisor bind-mount. Existing
security checks run during the normal template build.

## Updating existing VMs

From a trusted *physical-host* checkout (not from a file edited inside the VM):

```bash
./30-ensure-lab-tools.sh lab-vm-NAME
```

For current packaged `gnosislab` MCP images this replaces the two
protected files, updates the Quadlet when required and restarts the trusted
container only **after** trusted files are installed. It does not rebuild
the golden VM image.

For a pre-package legacy MCP image, the upgrader refuses to install
a workspace copy of an older supervisor in the trusted location.
Use the explicit MCP-container migration path:

```bash
./30-ensure-lab-tools.sh lab-vm-NAME --rebuild-mcp-image
```

That rebuilds **only the MCP container image**, defers restart until
the protected files and Quadlet are installed, then restarts the service.
This does not rerun the one-hour VM image build.

**Important:** the actual installed runtime must be verified on disposable
VMs before updating valued research environments. Repository CI performs
static regression and syntax tests; it cannot exercise libvirt/Podman.

## Runtime acceptance checks

Run `bash /srv/lab/workspace/ml-labloop/deploy/security-battery.sh`
as `lab` in a disposable clone, and require:
- `trusted-entrypoint-root-owned`: PASS
- `trusted-seccomp-root-owned`: PASS
- `trusted-quadlet-mount`: PASS, or WARN when the mcp home is inaccessible
  (inspect as root in that case).
- MCP services remain healthy and the normal functional battery passes.
- Changing the agent-writable workspace supervisor does not alter the live
  trusted container on restart.

Root-side inspection, if the unit isn't readable as `lab`:

```bash
sudo grep -E '^(SeccompProfile|Volume)=' \
  /home/mcp/.config/containers/systemd/lab-cnt-mcp.container
sudo stat -c '%U:%G %a %n' \
  /etc/labloop/seccomp-labloop.json \
  /usr/local/libexec/labloop-mcp-entrypoint
```

No changes to GnosisLab's Bubblewrap trial sandbox, MCP bearer
authentication, `SYS_ADMIN` runtime capability, `lab` sudo rights or network
policy are included. Those are separate audit findings and require explicit
approval.
