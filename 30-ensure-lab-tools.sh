#!/usr/bin/env bash
# 30-ensure-lab-tools.sh — bring any running lab VM up to the current
# tooling level. Idempotent: pushes the repo's deploy/ files into the
# guest, installs what belongs to root, refreshes the workspace copy,
# and updates the hostile-zone quadlet (restarting lab-cnt-exp ONLY if
# its definition changed).
#
#   ./30-ensure-lab-tools.sh <vm>     one VM
#   ./30-ensure-lab-tools.sh all      every running lab-vm-*
#
#   --rebuild-mcp-image   also restage the gnosislab package context
#                         (wheelhouse + sdist configs from the artifact
#                         cache) and `podman build` lab-img-mcp as mcp
#                         on the VM, then restart lab-cnt-mcp — the roll
#                         path for server-code fixes AND the deliberate
#                         38xxx->28xxx vintage migration
#
# Why this exists: clones made from a template built BEFORE a tooling
# change carry the old stack (no labloop-export, no /incoming mount).
# New templates bake everything in via create-lab-template; this is the
# upgrade path for VMs that already exist.
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(pwd)
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/labloop"
# gnosislab pin — same single source of truth as prefetch-cache.sh
eval "$(sed -n '/^GNOSISLAB_VER=/p' "$REPO/create-lab-template")"
GNOSISLAB_VER="${GNOSISLAB_VER:-0.1.42}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
die()  { echo "30-ensure: $*" >&2; exit 1; }
note() { echo "  ==> $*"; }

REBUILD_IMAGE=0
REBUILD_EXP=0
for a in "$@"; do
    [ "$a" = "--rebuild-mcp-image" ] && REBUILD_IMAGE=1
    [ "$a" = "--rebuild-exp-image" ] && REBUILD_EXP=1
done
TARGET=${1:?"usage: ./30-ensure-lab-tools.sh <vm>|all [--rebuild-mcp-image]"}
id -nG | grep -qw libvirt || exec sg libvirt -c "$0 $*"

# Record the preferred video mode without forcing XRandR at the greeter
# or user session. SPICE/virtio negotiates the active mode.
if [ -f "$REPO/labloop.conf" ]; then . "$REPO/labloop.conf"; fi
RES_X="${LABLOOP_RES_X:-2560}"
RES_Y="${LABLOOP_RES_Y:-1440}"
REFRESH="${LABLOOP_REFRESH:-75}"
printf 'RES_X=%s\nRES_Y=%s\nREFRESH=%s\n' "$RES_X" "$RES_Y" "$REFRESH" \
    > "$WORK/display.conf"

# ------------------------------------------------------------------
# Shared durable guest-agent driver. Inlined guest-exec-status polling
# lost the process whenever QGA briefly stopped responding and could
# report a truncated upload as successful. The maintained driver retries
# transient RPC errors and verifies each guest-file-write byte count.
# ------------------------------------------------------------------
QGA_DRIVER="$REPO/scripts/qga.py"
[ -f "$QGA_DRIVER" ] || die "missing QGA driver: $QGA_DRIVER"
qga_exec() {
    local vm=$1
    shift
    python3 "$QGA_DRIVER" "$vm" exec "$@"
}
qga_push() {
    local vm=$1
    shift
    python3 "$QGA_DRIVER" "$vm" push "$@"
}

rebuild_mcp_image() {
    local vm=$1
    # Same package ctx as create-lab-template: wheelhouse + sdist
    # configs from the artifact cache, no source tree. Image=lab-img-mcp
    # is a LOCAL image in mcp's rootless podman — the only way new
    # server code reaches the zone is an in-place build + restart here.
    # This is also the deliberate 38xxx -> 28xxx migration: the rebuilt
    # image carries the gnosislab port block, and the next ports.env
    # derive picks it up everywhere downstream automatically.
    if [ "$GNOSISLAB_VER" = latest ]; then
        [ -s "$CACHE_ROOT/gnosislab-version" ] ||
            { echo "  FAIL: set GNOSISLAB_VER or warm the artifact cache first" >&2; return 1; }
        GNOSISLAB_VER="$(cat "$CACHE_ROOT/gnosislab-version")"
        echo "  note: pinned cached GnosisLab release $GNOSISLAB_VER"
    fi
    [[ "$GNOSISLAB_VER" =~ ^[0-9][A-Za-z0-9.+_-]*$ ]] ||
        { echo "  FAIL: invalid GnosisLab version" >&2; return 1; }
    note "staging gnosislab==$GNOSISLAB_VER build context"
    rm -rf "$WORK/mcp"
    mkdir -p "$WORK/mcp/pkgs/wheels" "$WORK/mcp/pkgs/gnosislab"
    local offline=0
    if compgen -G "$CACHE_ROOT/wheels/gnosislab/gnosislab-${GNOSISLAB_VER}-*.whl" >/dev/null \
       && [ -f "$CACHE_ROOT/pkgs/gnosislab/ports.env" ]; then
        cp -a "$CACHE_ROOT/wheels/gnosislab/." "$WORK/mcp/pkgs/wheels/"
        cp -a "$CACHE_ROOT/pkgs/gnosislab/." "$WORK/mcp/pkgs/gnosislab/"
        offline=1
    else
        echo "  note: no cached wheelhouse — in-guest build will fetch PyPI"
    fi
    cp "$REPO/containers/mcp/Containerfile" \
       "$REPO/containers/mcp/entrypoint.sh" "$WORK/mcp/"
    tar -C "$WORK/mcp" -cf "$WORK/mcp-ctx.tar" .
    note "pushing context + building lab-img-mcp as mcp (minutes)"
    qga_push "$vm" "$WORK/mcp-ctx.tar" /tmp/mcp-ctx.tar \
        || { echo "  FAIL: context push"; return 1; }
    qga_exec "$vm" "
        mkdir -p /home/mcp/build/mcp &&
        tar -xf /tmp/mcp-ctx.tar -C /home/mcp/build/mcp &&
        rm -f /tmp/mcp-ctx.tar &&
        chown -R mcp:mcp /home/mcp/build &&
        su - mcp -c 'podman build -t lab-img-mcp \
            --build-arg GNOSISLAB_VERSION=$GNOSISLAB_VER \
            --build-arg OFFLINE=$offline \
            -f /home/mcp/build/mcp/Containerfile /home/mcp/build/mcp' &&
        rm -rf /home/mcp/build" \
        || { echo "  FAIL: image build"; return 1; }
    # The caller must first install the root-owned seccomp profile and
    # supervisor, then render the new quadlet and restart exactly once.
    # Restarting here could execute a compromised legacy workspace mount.
    echo "  trusted image rebuilt; deferring restart until protected assets are installed"
}

rebuild_exp_image() {
    local vm=$1
    local stage="/var/lib/gnosislab-exp-recovery"
    local expected_sha
    note "rebuilding experiment image from trusted host checkout (may take minutes)"
    mkdir -p "$WORK/experiment"
    cp "$REPO/containers/experiment/Containerfile" \
       "$REPO/containers/experiment/pip" "$WORK/experiment/"
    tar -C "$WORK/experiment" -cf "$WORK/experiment.tar" .
    expected_sha="$(sha256sum "$WORK/experiment.tar" | cut -d' ' -f1)"

    # Prepare a root-only staging area first. Guest /tmp is not a safe
    # transport destination and may be cleared during QGA disruptions.
    qga_exec "$vm" "set -eu
        test ! -L '$stage'
        install -d -m 0700 -o root -g root '$stage'
        test -d '$stage'
        test -O '$stage'" ||
        { echo "  FAIL: cannot prepare protected image staging" >&2; return 1; }

    note "uploading trusted experiment context (SHA-256 verification)"
    qga_push "$vm" "$WORK/experiment.tar" "$stage/context.part" ||
        { echo "  FAIL: QGA upload interrupted; archive not installed" >&2; return 1; }

    # Verify the exact bytes before any extraction or Podman build.
    # A reconnect after guest-file-write must never be accepted as a
    # completed transfer without this comparison.
    qga_exec "$vm" "set -eu
        test ! -L '$stage/context.part'
        printf '%s  %s\\n' '$expected_sha' '$stage/context.part' |
            sha256sum -c -
        mv -f '$stage/context.part' '$stage/context.tar'" ||
        { echo "  FAIL: image context checksum mismatch; build refused" >&2; return 1; }

    # A durable guest-side job continues during brief QGA outages.
    # Do not retry an unknown-state Podman build with a different PID.
    note "building trusted lab-img-exp in exp rootless Podman"
    qga_exec "$vm" "set -eu
        test ! -L /home/exp/build
        install -d -m 0755 -o exp -g exp /home/exp/build/experiment
        tar -xf '$stage/context.tar' -C /home/exp/build/experiment
        chown -R exp:exp /home/exp/build
        su - exp -c 'podman build -t lab-img-exp -f /home/exp/build/experiment/Containerfile /home/exp/build/experiment'
        su - exp -c 'podman image exists lab-img-exp'
        rm -rf /home/exp/build/experiment
        rm -f '$stage/context.tar'" ||
        { echo "  FAIL: experiment image build or verification failed" >&2; return 1; }
}

ensure_vm() {
    local vm=$1
    echo; echo "### $vm"
    virsh -c qemu:///system list --name | grep -qx "$vm" \
        || { echo "  skip: not running"; return 0; }
    qga_exec "$vm" "id -u" >/dev/null 2>&1 \
        || { echo "  FAIL: guest-agent is not responding in $vm" >&2; return 1; }

    note "pushing deploy files"
    for f in labloop-export labloop-exec labloop-build \
             labloop-fault labloop-update-opencode \
             labloop.sudoers labloop-tmpfiles.conf \
             security-battery.sh functional-battery.sh \
             GENESIS-RESEARCH-PROMPT.md DATA-MOVEMENT-MANUAL.md \
             AGENT-LAB-GUIDE.md SECURITY-MANUAL.md \
             check-lab-ready.sh \
             labloop-display.sh labloop-display.desktop \
             labloop-display-lightdm.conf \
             opencode.json opencode.jsonc configure-host-models.py; do
        qga_push "$vm" "$REPO/deploy/$f" "/tmp/ensure-$f"
    done
    qga_push "$vm" "$WORK/display.conf" /tmp/ensure-display.conf
    # render the hostile-zone ceiling against the guest's ACTUAL size
    # (~5/8 of its vcpus, ~3/4 of its RAM) — the quadlet carries
    # @EXP_CPUS@/@EXP_MEM_MIB@ placeholders
    local g_cpus g_mib exp_cpus exp_mib
    g_cpus=$(qga_exec "$vm" "nproc" | tail -1); g_cpus=${g_cpus:-0}
    g_mib=$(qga_exec "$vm" \
        "awk '/MemTotal/{print int(\$2/1024)}' /proc/meminfo" | tail -1)
    g_mib=${g_mib:-0}
    exp_cpus=$(( g_cpus * 5 / 8 )); [ "$exp_cpus" -lt 1 ] && exp_cpus=1
    exp_mib=$(( g_mib * 3 / 4 ));  [ "$exp_mib" -lt 256 ] && exp_mib=256
    sed -e "s/@EXP_CPUS@/$exp_cpus/g" -e "s/@EXP_MEM_MIB@/$exp_mib/g" \
        "$REPO/deploy/quadlets/lab-cnt-exp.container" \
        > "$WORK/lab-cnt-exp.container"
    qga_push "$vm" "$WORK/lab-cnt-exp.container" /tmp/ensure-lab-cnt-exp.container

    # --rebuild-mcp-image runs BEFORE the vintage derive: everything
    # downstream (ports.env render, entrypoint vintage, watchdog config)
    # must see the image that will actually run. On a 38xxx VM this is
    # the deliberate migration — the same pass then derives 28xxx and
    # pushes the package-era entrypoint.
    if [ "$REBUILD_IMAGE" = 1 ]; then
        rebuild_mcp_image "$vm" || { echo "  FAIL: trusted image rebuild failed"; return 1; }
    fi

    if [ "$REBUILD_EXP" = 1 ]; then
        rebuild_exp_image "$vm" ||
            { echo "  FAIL: experiment image rebuild failed" >&2; return 1; }
    fi
    if ! qga_exec "$vm" "su - exp -c 'podman image exists lab-img-exp'" >/dev/null 2>&1; then
        echo "  FAIL: exp image lab-img-exp missing" >&2
        echo "  Restore explicitly: ./30-ensure-lab-tools.sh $vm --rebuild-exp-image" >&2
        return 1
    fi

    # Restore desktop files before any MCP image checks. This is also
    # the upgrade path for existing clones with missing launchers.
    if ! bash "$REPO/scripts/ensure-vm-desktop.sh" "$vm"; then
        echo "  FAIL: desktop restoration failed" >&2
        return 1
    fi

    # Upgrade the GUI clock independently of trusted MCP health.
    # Install from host checkout and clear the obsolete one-shot stamp.
    qga_push "$vm" "$REPO/deploy/labloop-panel-clock.sh" /usr/local/libexec/labloop-panel-clock.sh
    qga_push "$vm" "$REPO/deploy/labloop-panel-clock.desktop" /etc/xdg/autostart/labloop-panel-clock.desktop
    qga_exec "$vm" 'chmod 0755 /usr/local/libexec/labloop-panel-clock.sh &&
        chmod 0644 /etc/xdg/autostart/labloop-panel-clock.desktop &&
        chown root:root /usr/local/libexec/labloop-panel-clock.sh /etc/xdg/autostart/labloop-panel-clock.desktop &&
        rm -f /home/lab/.config/.labloop-clock-done &&
        timedatectl set-timezone UTC' || { echo "  FAIL: UTC clock setup"; return 1; }

    # Diagnose the trusted image separately from its configuration.
    # Do not treat a failed rootless Podman probe as evidence that an
    # image has disappeared. Avoid printing potentially sensitive env.
    if ! qga_exec "$vm" "su - mcp -c 'podman image exists lab-img-mcp'" >/dev/null 2>&1; then
        echo "  FAIL: mcp user cannot see local image lab-img-mcp" >&2
        echo "  Check rootless Podman storage and user runtime before rebuilding:" >&2
        echo "    python3 scripts/qga.py $vm exec \"su - mcp -c 'podman images --format {{.Repository}}:{{.Tag}}'\"" >&2
        echo "  If the image is genuinely absent, use the explicit rebuild flag." >&2
        echo "  refusing an insecure partial upgrade" >&2
        return 1
    fi

    # ports.env derives from the VM's OWN lab-img-mcp image — never the
    # repo: the render must match the vintage actually installed
    # (/opt/gnosislab on packaged images, /opt/ml-scientist on
    # pre-switch ones — the glob covers both). From the image, not
    # `podman exec`: the watchdog needs it when the container is down.
    # Fallback is the VM's installed copy — equally vintage-true.
    # Run the image without network access, using a shell entrypoint.
    # No remote image pull is permitted: source must be local to mcp.
    local ports_env_txt img_probe
    img_probe=$(qga_exec "$vm" "su - mcp -c 'podman image inspect lab-img-mcp >/dev/null 2>&1 &&
        podman run --pull=never --network=none --rm --entrypoint /bin/sh lab-img-mcp -c \"cat /opt/gnosislab/ports.env\"'" 2>&1) || {
        echo "  note: local image exists but offline port probe failed: $img_probe" >&2
        img_probe=""
    }
    ports_env_txt=$(printf '%s\n' "$img_probe" | sed -n '/^ML_[A-Z_]*=/p')
    if [ -z "$ports_env_txt" ]; then
        echo "  note: trying previously provisioned mcp-owned ports.env"
        ports_env_txt=$(qga_exec "$vm" "cat /home/mcp/.config/labloop/ports.env" 2>/dev/null || true)
    fi
    # A missing file is not grounds to invent new values. If the
    # installed image is missing or incomplete, rebuild explicitly
    # from the verified local artifact cache via --rebuild-mcp-image.
    if [ -z "$ports_env_txt" ]; then
        echo "  FAIL: cannot derive MCP ports.env from trusted image or installed config" >&2
        echo "  refusing an insecure partial upgrade" >&2
        echo "  Repair: verify the VM has lab-img-mcp, then use:" >&2
        echo "    ./30-ensure-lab-tools.sh $vm --rebuild-mcp-image" >&2
        return 1
    fi
    printf '%s\n' "$ports_env_txt" > "$WORK/ports.env"
    # Validate before sourcing untrusted or malformed file content;
    # require decimal loopback ports, no arbitrary shell expressions.
    if ! python3 "$REPO/scripts/validate-mcp-ports.py" "$WORK/ports.env"; then
        echo "  FAIL: invalid MCP ports.env; refusing an insecure partial upgrade" >&2
        return 1
    fi
    local have_ports=1
    case "$ports_env_txt" in
        *ML_AGORA_PORT=38*) echo "  note: legacy 38xxx image, rebuild explicitly to migrate" ;;
    esac
    ( set -a; . "$WORK/ports.env"; set +a
      grep -oE '^ML_[A-Z_]+_PORT' "$WORK/ports.env" \
          | while read -r v; do
                printf 'PublishPort=127.0.0.1:%s:%s\n' "${!v}" "${!v}"
            done ) > "$WORK/mcp-ports.publish"
    # Only packaged images support the audited supervisor. Never copy
    # legacy supervisor code from lab-writable workspace into a trusted
    # executable path: an agent may already have changed it.
    # A legacy VM requires --rebuild-mcp-image to migrate deliberately.
    local img_pkg=0
    qga_exec "$vm" "su - mcp -c 'podman image exists lab-img-mcp && \
        podman run --rm --entrypoint sh lab-img-mcp \
        -c \"test -d /opt/gnosislab\"'" >/dev/null 2>&1 && img_pkg=1
    if [ "$img_pkg" != 1 ]; then
        echo "  FAIL: legacy MCP image; refusing to promote agent-writable executable"
        echo "  rebuild trusted MCP image explicitly with --rebuild-mcp-image"
        return 1
    fi

    # Source comes from the trusted host checkout via guest-agent, NEVER
    # from the driver-owned in-guest workspace. The files are installed
    # as root and checked before any mcp service restart.
    # Stage root-only, without trusting agent-writable /tmp paths.
    qga_exec "$vm" "install -d -m 0755 -o root -g root /etc/labloop /usr/local/libexec" \
        || { echo "  FAIL: trusted staging directories"; return 1; }
    qga_push "$vm" "$REPO/containers/mcp/entrypoint.sh" /usr/local/libexec/.labloop-mcp-next
    qga_push "$vm" "$REPO/deploy/seccomp-labloop.json" /etc/labloop/.seccomp-next
    if [ "$have_ports" = 1 ]; then
        printf '%s\n' 'Volume=/usr/local/libexec/labloop-mcp-entrypoint:/usr/local/bin/labloop-mcp:ro' \
            > "$WORK/mcp-entrypoint.mount"
        sed -e "/^@MCP_PORTS_PUBLISH@\$/r $WORK/mcp-ports.publish" \
            -e "/^@MCP_PORTS_PUBLISH@\$/d" \
            -e "/^@MCP_ENTRYPOINT_VOLUME@\$/r $WORK/mcp-entrypoint.mount" \
            -e "/^@MCP_ENTRYPOINT_VOLUME@\$/d" \
            "$REPO/deploy/quadlets/lab-cnt-mcp.container" \
            > "$WORK/lab-cnt-mcp.container"
        qga_push "$vm" \
            "$WORK/lab-cnt-mcp.container" /tmp/ensure-lab-cnt-mcp.container
        qga_push "$vm" "$WORK/ports.env" /tmp/ensure-ports.env
    fi
    qga_push "$vm" \
        "$REPO/deploy/labloop-mcp-watchdog" /tmp/ensure-watchdog
    qga_push "$vm" \
        "$REPO/deploy/quadlets/labloop-mcp-watchdog.service" \
        /tmp/ensure-watchdog.service
    qga_push "$vm" \
        "$REPO/deploy/quadlets/labloop-mcp-watchdog.timer" \
        /tmp/ensure-watchdog.timer

    # diagnostics reports from the cached gnosislab sdist payload ->
    # ~/Desktop/diagnostics (they are *.md — the workspace payload's
    # md-strip would remove them, so they ship via QGA directly)
    local diag_names=() b
    local diag_src="$CACHE_ROOT/pkgs/gnosislab/diagnostics"
    if [ -d "$diag_src" ]; then
        for f in "$diag_src"/*; do
            [ -f "$f" ] || continue
            b="$(basename "$f")"
            qga_push "$vm" "$f" "/tmp/ensure-diag-$b"
            diag_names+=("$b")
        done
    fi

    # content check, not existence — an older installed revision must
    # count as "needs update", or updated scripts would never roll out
    local diag_cmp=""
    if ((${#diag_names[@]})); then
        diag_cmp=" && test -d /home/lab/Desktop/diagnostics"
        for b in "${diag_names[@]}"; do
            diag_cmp="$diag_cmp && cmp -s '/tmp/ensure-diag-$b' \
                '/home/lab/Desktop/diagnostics/$b'"
        done
    fi
    # have_ports=0 degrades to "leave installed ports wiring alone" —
    # no /tmp/ensure-ports.env or rendered quadlet was pushed, so the
    # cmp legs must be true (not missing-file failures) and the install
    # legs must no-op.
    local ports_cmp="true" ports_inst="true" quadlet_cmp="true"
    if [ "$have_ports" = 1 ]; then
        ports_cmp="cmp -s /tmp/ensure-ports.env /home/mcp/.config/labloop/ports.env"
        ports_inst="install -m 0644 -o mcp -g mcp /tmp/ensure-ports.env /home/mcp/.config/labloop/ports.env"
        quadlet_cmp="cmp -s /tmp/ensure-lab-cnt-mcp.container /home/mcp/.config/containers/systemd/lab-cnt-mcp.container"
    fi
    # These protected assets must exist, be owned by root and match
    # this host checkout. Existing workspace files are never executed.
    local entry_cmp="cmp -s /usr/local/libexec/.labloop-mcp-next /usr/local/libexec/labloop-mcp-entrypoint && test \$(stat -c '%u:%a' /usr/local/libexec/labloop-mcp-entrypoint 2>/dev/null) = 0:755"
    local seccomp_cmp="cmp -s /etc/labloop/.seccomp-next /etc/labloop/seccomp-labloop.json && test \$(stat -c '%u:%a' /etc/labloop/seccomp-labloop.json 2>/dev/null) = 0:644"
    local need=0
    qga_exec "$vm" "
        cmp -s /tmp/ensure-labloop-export /usr/local/sbin/labloop-export &&
        cmp -s /tmp/ensure-labloop-exec /usr/local/sbin/labloop-exec &&
        cmp -s /tmp/ensure-labloop-build /usr/local/sbin/labloop-build &&
        cmp -s /tmp/ensure-labloop-fault /usr/local/sbin/labloop-fault &&
        cmp -s /tmp/ensure-labloop-update-opencode \
               /usr/local/sbin/labloop-update-opencode &&
        cmp -s /tmp/ensure-labloop.sudoers /etc/sudoers.d/labloop &&
        cmp -s /tmp/ensure-labloop-tmpfiles.conf /etc/tmpfiles.d/labloop.conf &&
        cmp -s /tmp/ensure-security-battery.sh \
               /srv/lab/workspace/ml-labloop/deploy/security-battery.sh &&
        cmp -s /tmp/ensure-functional-battery.sh \
               /srv/lab/workspace/ml-labloop/deploy/functional-battery.sh &&
        cmp -s /tmp/ensure-GENESIS-RESEARCH-PROMPT.md \
               /srv/lab/workspace/ml-labloop/deploy/GENESIS-RESEARCH-PROMPT.md &&
        cmp -s /tmp/ensure-DATA-MOVEMENT-MANUAL.md \
               /srv/lab/workspace/ml-labloop/deploy/DATA-MOVEMENT-MANUAL.md &&
        cmp -s /tmp/ensure-GENESIS-RESEARCH-PROMPT.md \
               /home/lab/GENESIS-RESEARCH-PROMPT.md &&
        test -L /home/lab/workspace/GENESIS-RESEARCH-PROMPT.md &&
        cmp -s /tmp/ensure-AGENT-LAB-GUIDE.md /home/lab/AGENT-LAB-GUIDE.md &&
        test -L /home/lab/workspace/AGENTS.md &&
        cmp -s /tmp/ensure-SECURITY-MANUAL.md /home/lab/SECURITY-MANUAL.md &&
        test -L /home/lab/workspace/SECURITY-MANUAL.md &&
        cmp -s /tmp/ensure-check-lab-ready.sh \
               /home/lab/Desktop/check-lab-ready.sh &&
        test -x /home/lab/.opencode/bin/opencode &&
        cmp -s /tmp/ensure-opencode-launcher /usr/local/bin/opencode &&
        cmp -s /tmp/ensure-opencode-update-command.md \
            /home/lab/.config/opencode/commands/update.md &&
        test -f /home/lab/.config/opencode/opencode.json &&
        test -f /home/lab/.config/opencode/opencode.jsonc &&
        cmp -s /tmp/ensure-lab-cnt-exp.container \
               /home/exp/.config/containers/systemd/lab-cnt-exp.container &&
        $quadlet_cmp &&
        $entry_cmp &&
        $seccomp_cmp &&
        cmp -s /tmp/ensure-display.conf /etc/labloop/display.conf &&
        cmp -s /tmp/ensure-labloop-display.sh \
               /usr/local/libexec/labloop-display.sh &&
        cmp -s /tmp/ensure-labloop-display.desktop \
               /etc/xdg/autostart/labloop-display.desktop &&
        cmp -s /tmp/ensure-labloop-display-lightdm.conf \
               /etc/lightdm/lightdm.conf.d/50-labloop-display.conf &&
        test -d /var/lib/labloop-export/user &&
        test -d /var/lib/labloop-export/root &&
        test -d /srv/lab/incoming &&
        cmp -s /tmp/ensure-watchdog /home/mcp/.local/sbin/labloop-mcp-watchdog &&
        cmp -s /tmp/ensure-watchdog.service \
               /home/mcp/.config/systemd/user/labloop-mcp-watchdog.service &&
        cmp -s /tmp/ensure-watchdog.timer \
               /home/mcp/.config/systemd/user/labloop-mcp-watchdog.timer &&
        $ports_cmp &&
        # Files alone do not establish runtime readiness. In particular
        # an unchanged exp Quadlet can still be failed from an earlier
        # missing-image startup. Let the normal recovery path repair it.
        su - exp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
            systemctl --user is-active --quiet lab-cnt-exp' \
            >/dev/null 2>&1 &&
        su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
            systemctl --user is-enabled --quiet labloop-mcp-watchdog.timer' \
            >/dev/null 2>&1 &&
        su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
            podman exec lab-cnt-mcp /opt/trial-env/bin/python -c \"import numpy\"' \
            >/dev/null 2>&1$diag_cmp" >/dev/null 2>&1 || need=1
    [ "$need" = 0 ] && [ "$REBUILD_IMAGE" = 0 ] &&
        [ "$REBUILD_EXP" = 0 ] \
        && { echo "  already current"; return 0; }

    note "installing (root side)"
    qga_exec "$vm" "
        install -m 0755 -o root -g root /tmp/ensure-labloop-export /usr/local/sbin/labloop-export &&
        install -m 0755 -o root -g root /tmp/ensure-labloop-exec /usr/local/sbin/labloop-exec &&
        install -m 0755 -o root -g root /tmp/ensure-labloop-build /usr/local/sbin/labloop-build &&
        install -m 0755 -o root -g root /tmp/ensure-labloop-fault /usr/local/sbin/labloop-fault &&
        install -m 0755 -o root -g root /tmp/ensure-labloop-update-opencode \
            /usr/local/sbin/labloop-update-opencode &&
        install -m 0440 -o root -g root /tmp/ensure-labloop.sudoers /etc/sudoers.d/labloop &&
        install -m 0644 -o root -g root /tmp/ensure-labloop-tmpfiles.conf /etc/tmpfiles.d/labloop.conf &&
        install -d -m 0755 -o root -g root /etc/labloop /usr/local/libexec &&
        install -m 0755 -o root -g root /usr/local/libexec/.labloop-mcp-next /usr/local/libexec/labloop-mcp-entrypoint &&
        install -m 0644 -o root -g root /etc/labloop/.seccomp-next /etc/labloop/seccomp-labloop.json &&
        install -m 0644 -o root -g root /tmp/ensure-display.conf \
            /etc/labloop/display.conf &&
        rm -f /etc/lightdm/lightdm.conf.d/50-labloop-display.conf \
              /etc/xdg/autostart/labloop-display.desktop \
              /usr/local/libexec/labloop-display.sh &&
        systemd-tmpfiles --create /etc/tmpfiles.d/labloop.conf &&
        rm -rf /run/labloop-export &&
        install -d -m 0755 -o lab -g lab /srv/lab/incoming &&
        visudo -c | grep -q 'labloop: parsed OK'" \
        || { echo "  FAIL: root-side install"; return 1; }

    note "refreshing workspace deploy/ (lab-owned)"
    qga_exec "$vm" "
        install -d -o lab -g lab /srv/lab/workspace/ml-labloop/deploy &&
        install -m 0755 -o lab -g lab /tmp/ensure-labloop-export \
            /srv/lab/workspace/ml-labloop/deploy/labloop-export &&
        install -m 0755 -o lab -g lab /tmp/ensure-labloop-exec \
            /srv/lab/workspace/ml-labloop/deploy/labloop-exec &&
        install -m 0755 -o lab -g lab /tmp/ensure-labloop-build \
            /srv/lab/workspace/ml-labloop/deploy/labloop-build &&
        install -m 0755 -o lab -g lab /tmp/ensure-labloop-fault \
            /srv/lab/workspace/ml-labloop/deploy/labloop-fault &&
        install -m 0755 -o lab -g lab /tmp/ensure-labloop-update-opencode \
            /srv/lab/workspace/ml-labloop/deploy/labloop-update-opencode &&
        install -m 0644 -o lab -g lab /tmp/ensure-security-battery.sh \
            /srv/lab/workspace/ml-labloop/deploy/security-battery.sh &&
        install -m 0644 -o lab -g lab /tmp/ensure-functional-battery.sh \
            /srv/lab/workspace/ml-labloop/deploy/functional-battery.sh &&
        install -m 0644 -o lab -g lab /tmp/ensure-GENESIS-RESEARCH-PROMPT.md \
            /srv/lab/workspace/ml-labloop/deploy/GENESIS-RESEARCH-PROMPT.md &&
        install -m 0644 -o lab -g lab /tmp/ensure-DATA-MOVEMENT-MANUAL.md \
            /srv/lab/workspace/ml-labloop/deploy/DATA-MOVEMENT-MANUAL.md &&
        install -m 0644 -o lab -g lab /tmp/ensure-GENESIS-RESEARCH-PROMPT.md \
            /home/lab/GENESIS-RESEARCH-PROMPT.md &&
        ln -sf ../GENESIS-RESEARCH-PROMPT.md \
            /home/lab/workspace/GENESIS-RESEARCH-PROMPT.md &&
        chown -h lab:lab /home/lab/workspace/GENESIS-RESEARCH-PROMPT.md &&
        install -m 0644 -o lab -g lab /tmp/ensure-AGENT-LAB-GUIDE.md \
            /srv/lab/workspace/ml-labloop/deploy/AGENT-LAB-GUIDE.md &&
        install -m 0644 -o lab -g lab /tmp/ensure-AGENT-LAB-GUIDE.md \
            /home/lab/AGENT-LAB-GUIDE.md &&
        ln -sf ../AGENT-LAB-GUIDE.md /home/lab/workspace/AGENTS.md &&
        chown -h lab:lab /home/lab/workspace/AGENTS.md &&
        install -m 0644 -o lab -g lab /tmp/ensure-SECURITY-MANUAL.md \
            /srv/lab/workspace/ml-labloop/deploy/SECURITY-MANUAL.md &&
        install -m 0644 -o lab -g lab /tmp/ensure-SECURITY-MANUAL.md \
            /home/lab/SECURITY-MANUAL.md &&
        ln -sf ../SECURITY-MANUAL.md /home/lab/workspace/SECURITY-MANUAL.md &&
        chown -h lab:lab /home/lab/workspace/SECURITY-MANUAL.md &&
        install -d -m 0755 -o lab -g lab /home/lab/Desktop &&
        install -m 0755 -o lab -g lab /tmp/ensure-check-lab-ready.sh \
            /home/lab/Desktop/check-lab-ready.sh &&
        install -d -m 0755 -o lab -g lab /home/lab/.config/opencode \
            /home/lab/.config/opencode/commands /home/lab/.opencode \
            /home/lab/.opencode/bin &&
        { test -e /home/lab/.config/opencode/opencode.json ||
          install -m 0644 -o lab -g lab /tmp/ensure-opencode.json \
                /home/lab/.config/opencode/opencode.json; } &&
        { test -e /home/lab/.config/opencode/opencode.jsonc ||
          install -m 0644 -o lab -g lab /tmp/ensure-opencode.jsonc \
                /home/lab/.config/opencode/opencode.jsonc; } &&
        { test -x /home/lab/.opencode/bin/opencode ||
          install -m 0755 -o lab -g lab /usr/local/bin/opencode \
                /home/lab/.opencode/bin/opencode; } &&
        install -m 0755 -o root -g root /tmp/ensure-opencode-launcher \
            /usr/local/bin/opencode &&
        install -m 0644 -o lab -g lab /tmp/ensure-opencode-update-command.md \
            /home/lab/.config/opencode/commands/update.md &&
        install -m 0755 -o lab -g lab /tmp/ensure-opencode-v2-migrate.py \
            /home/lab/.config/opencode/opencode-v2-migrate.py &&
        su - lab -c 'python3 /home/lab/.config/opencode/opencode-v2-migrate.py' &&
        install -m 0755 -o lab -g lab /tmp/ensure-configure-host-models.py \
            /home/lab/Desktop/configure-host-models.py &&
        install -m 0440 -o lab -g lab /tmp/ensure-labloop.sudoers \
            /srv/lab/workspace/ml-labloop/deploy/labloop.sudoers &&
        install -m 0644 -o lab -g lab /tmp/ensure-labloop-tmpfiles.conf \
            /srv/lab/workspace/ml-labloop/deploy/labloop-tmpfiles.conf &&
        install -d -o lab -g lab /srv/lab/workspace/ml-labloop/containers/mcp" \
        || echo "  warn: workspace refresh failed (workspace absent?)"

    if ((${#diag_names[@]})); then
        note "installing diagnostics -> ~/Desktop/diagnostics"
        qga_exec "$vm" \
            "install -d -m 0755 -o lab -g lab /home/lab/Desktop/diagnostics" \
            || echo "  warn: diagnostics dir failed"
        for b in "${diag_names[@]}"; do
            qga_exec "$vm" "install -m 0644 -o lab -g lab '/tmp/ensure-diag-$b' \
                '/home/lab/Desktop/diagnostics/$b' && rm -f '/tmp/ensure-diag-$b'" \
                || echo "  warn: diagnostics file $b failed"
        done
    fi

    # Scrubbed/cloned guests can retain the users but lose their Quadlet
    # directories. The original template creates these before startup;
    # reconstruct only the expected per-user directories, without touching
    # container storage or trusting anything in the lab workspace.
    # Refuse symlinked ancestors to avoid crossing the account boundary.
    note "ensuring exp/mcp Quadlet directories"
    qga_exec "$vm" '
        set -eu
        for account in exp mcp; do
            test "$(getent passwd "$account" | cut -d: -f6)" = "/home/$account" || exit 1
            home="/home/$account"
            for path in "$home" "$home/.config" "$home/.config/containers" \
                        "$home/.config/containers/systemd"; do
                if test -L "$path"; then
                    echo "refusing symlinked Quadlet path: $path" >&2
                    exit 1
                fi
            done
            install -d -m 0755 -o "$account" -g "$account" \
                "$home/.config" "$home/.config/containers" \
                "$home/.config/containers/systemd"
            test "$(stat -c %U:%G "$home/.config/containers/systemd")" = \
                "$account:$account" || exit 1
        done' || {
        echo "  FAIL: exp/mcp Quadlet directory preflight" >&2
        return 1
    }

    # Recover the original experiment-zone ACLs before Podman statfs()
    # validates its bind mounts. Sealed clones may retain data and images
    # while /srv/lab loses exp's search permission. Never chmod /srv/lab
    # for everyone or grant exp any rights on the protected mcp-state.
    note "verifying exp bind-mount traversal and ACLs"
    qga_exec "$vm" '
        set -eu
        fail() { echo "exp mount preflight: $*" >&2; exit 1; }
        command -v setfacl >/dev/null 2>&1 ||
            fail "setfacl unavailable"
        for path in /srv /srv/lab /srv/lab/workspace /srv/lab/incoming \
                    /srv/lab/exchange /srv/lab/experiments; do
            test -d "$path" && test ! -L "$path" ||
                fail "missing or symlinked directory: $path"
        done
        su - exp -c "test -x /srv" ||
            fail "exp cannot traverse /srv"
        if ! su - exp -c "test -x /srv/lab"; then
            setfacl -m u:exp:--x /srv/lab ||
                fail "cannot grant exp traverse-only access to /srv/lab"
        fi
        # Workspace and incoming data are read-only in the Quadlet;
        # keep the guest-side ACLs read/execute only, never write.
        setfacl -m u:exp:r-x /srv/lab/workspace ||
            fail "cannot restore exp read-only workspace ACL"
        setfacl -m u:exp:r-x /srv/lab/incoming ||
            fail "cannot restore exp read-only incoming ACL"
        # Writable experimental data is owned by exp, as in the template.
        # Do not recurse into contents; preserve existing research files.
        for path in /srv/lab/exchange /srv/lab/experiments; do
            chown exp:exp "$path" ||
                fail "cannot restore exp-owned directory: $path"
            chmod u+rwx "$path" ||
                fail "cannot restore exp directory permissions: $path"
        done
        setfacl -m u:lab:rwx /srv/lab/exchange ||
            fail "cannot restore lab artifact-handoff ACL"
        for path in /srv/lab/workspace /srv/lab/incoming \
                    /srv/lab/exchange /srv/lab/experiments; do
            su - exp -c "test -r \"$path\" && test -x \"$path\"" ||
                fail "exp cannot read/traverse mount: $path"
        done
        for path in /srv/lab/exchange /srv/lab/experiments; do
            su - exp -c "test -w \"$path\"" ||
                fail "exp cannot write experiment mount: $path"
        done
        su - exp -c "test ! -r /srv/lab/mcp-state/ingest.env" ||
            fail "security boundary violation: exp can read MCP token"
    ' || { echo "  FAIL: experiment bind-mount preflight" >&2; return 1; }

    # quadlet: update definition; restart lab-cnt-exp only if it changed
    local changed exp_quadlet_failed=0
    changed=$(qga_exec "$vm" "
        if cmp -s /tmp/ensure-lab-cnt-exp.container \
                  /home/exp/.config/containers/systemd/lab-cnt-exp.container 2>/dev/null; then
            echo same
        else echo changed; fi" | tr -d '[:space:]')
    if [ "$changed" = changed ]; then
        note "quadlet changed — updating + restarting lab-cnt-exp (the /incoming mount)"
        qga_exec "$vm" "
            install -m 0644 -o exp -g exp /tmp/ensure-lab-cnt-exp.container \
                /home/exp/.config/containers/systemd/lab-cnt-exp.container &&
            su - exp -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u) \
                systemctl --user daemon-reload && systemctl --user restart lab-cnt-exp'" \
            || { echo "  FAIL: hostile-zone quadlet install/restart" >&2; exp_quadlet_failed=1; }
    else
        echo "  quadlet already current"
    fi

    # When an image was absent at an earlier startup, systemd may have
    # exhausted its restart limit. Replacing/restoring the image does not
    # change the Quadlet file; recover an inactive service explicitly.
    # Keep the working experiment container untouched when it is active.
    if [ "$exp_quadlet_failed" = 0 ] &&
       ! qga_exec "$vm" "su - exp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
           systemctl --user is-active --quiet lab-cnt-exp'" >/dev/null 2>&1; then
        note "experiment service inactive — clearing failure limit and starting"
        qga_exec "$vm" "su - exp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
            systemctl --user reset-failed lab-cnt-exp &&
            systemctl --user daemon-reload &&
            systemctl --user start lab-cnt-exp'" ||
            { echo "  FAIL: cannot recover inactive experiment container" >&2; exp_quadlet_failed=1; }
    fi
    # A successful upgrade must never report healthy if the experiment
    # service was left stopped, even when its Quadlet definition matches.
    if [ "$exp_quadlet_failed" = 0 ] &&
       ! qga_exec "$vm" "su - exp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
           systemctl --user is-active --quiet lab-cnt-exp'" >/dev/null 2>&1; then
        echo "  FAIL: experiment container remains inactive" >&2
        exp_quadlet_failed=1
    fi

    if [ "$have_ports" = 1 ]; then
    changed=$(qga_exec "$vm" "
        if cmp -s /tmp/ensure-lab-cnt-mcp.container \
                  /home/mcp/.config/containers/systemd/lab-cnt-mcp.container 2>/dev/null; then
            echo same
        else echo changed; fi" | tr -d '[:space:]')
    # Any changed trusted executable or policy also requires a service
    # restart: the old container may still be using the old mount/policy.
    if [ "$changed" = changed ]; then
        note "mcp quadlet changed — installing protected configuration"
        qga_exec "$vm" "
            install -m 0644 -o mcp -g mcp /tmp/ensure-lab-cnt-mcp.container \
                /home/mcp/.config/containers/systemd/lab-cnt-mcp.container" \
            || { echo "  FAIL: mcp quadlet install"; return 1; }
    fi
    # Verify the protected MCP token file before restarting Quadlet.
    # Neither the token nor its value is logged, even on failure. The
    # mcp account must be able to traverse /srv/lab while other accounts
    # still cannot read /srv/lab/mcp-state (0700, mcp-owned).
    note "verifying mcp ingest token ownership and traversal"
    qga_exec "$vm" '
        set -eu
        fail() { echo "ingest.env preflight: $*" >&2; exit 1; }
        parent=/srv/lab
        path="$parent/mcp-state"
        file="$path/ingest.env"
        test -d /srv && test ! -L /srv ||
            fail "/srv is missing or symlinked"
        test -d "$parent" && test ! -L "$parent" ||
            fail "/srv/lab is missing or symlinked"
        test -d "$path" && test ! -L "$path" ||
            fail "mcp-state directory is missing or symlinked"
        test ! -L "$file" ||
            fail "ingest.env is symlinked; refusing to follow it"

        chown mcp:mcp "$path" ||
            fail "cannot set mcp-state directory ownership"
        chmod 0700 "$path" ||
            fail "cannot restrict mcp-state directory permissions"
        if test -e "$file"; then
            test -f "$file" ||
                fail "existing ingest.env is not a regular file"
        else
            umask 077
            token="$(head -c 32 /dev/urandom | base64 -w0)" ||
                fail "cannot generate ingest token"
            (set -C; printf "ML_EPISTEME_INGEST_TOKEN=%s\n" "$token" > "$file") ||
                fail "cannot create ingest token securely"
        fi
        chown mcp:mcp "$file" ||
            fail "cannot set ingest.env ownership"
        chmod 0600 "$file" ||
            fail "cannot restrict ingest.env to mcp"

        # The state directory may be secure and correctly owned while
        # a sealed clone has /srv/lab without search permission for mcp.
        # Grant ONLY mcp directory traversal, never general read access.
        su - mcp -c "test -x /srv" ||
            fail "mcp cannot traverse /srv"
        if ! su - mcp -c "test -x /srv/lab"; then
            command -v setfacl >/dev/null 2>&1 ||
                fail "mcp cannot traverse /srv/lab and ACL tooling is absent"
            setfacl -m u:mcp:--x /srv/lab ||
                fail "cannot grant mcp traverse-only ACL on /srv/lab"
        fi
        su - mcp -c "test -x /srv/lab" ||
            fail "mcp still cannot traverse /srv/lab"
        su - mcp -c "test -x /srv/lab/mcp-state" ||
            fail "mcp cannot traverse mcp-state after ownership repair"
        su - mcp -c "test -r /srv/lab/mcp-state/ingest.env" ||
            fail "mcp still cannot read ingest.env"
        test "$(stat -c %U:%G "$path")" = mcp:mcp ||
            fail "mcp-state owner verification failed"
        test "$(stat -c %a "$path")" = 700 ||
            fail "mcp-state mode verification failed"
        test "$(stat -c %U:%G "$file")" = mcp:mcp ||
            fail "ingest.env owner verification failed"
        test "$(stat -c %a "$file")" = 600 ||
            fail "ingest.env mode verification failed"
    ' || { echo "  FAIL: trusted MCP token permissions (details above)" >&2; return 1; }

    # The Quadlet binds /srv/lab/trial-env at container creation time.
    # Earlier upgrades populated this directory only AFTER restarting MCP,
    # leaving freshly sealed/cloned guests unable to start the container.
    # Create the empty mcp-owned mount point now; never clear an existing
    # environment or follow an agent-provided symlink.
    note "verifying MCP bind-mount prerequisites"
    qga_exec "$vm" '
        set -eu
        test ! -L /srv/lab/trial-env ||
            { echo "FAIL: symlinked /srv/lab/trial-env" >&2; exit 1; }
        install -d -m 0755 -o mcp -g mcp /srv/lab/trial-env
        test "$(stat -c %U:%G /srv/lab/trial-env)" = mcp:mcp ||
            { echo "FAIL: incorrect owner for /srv/lab/trial-env" >&2; exit 1; }
        for p in /srv/lab/mcp-state /srv/lab/exchange /srv/lab/incoming; do
            test -d "$p" && test ! -L "$p" ||
                { echo "FAIL: missing or symlinked MCP mount: $p" >&2; exit 1; }
        done
        test -f /usr/local/libexec/labloop-mcp-entrypoint &&
            test -f /etc/labloop/seccomp-labloop.json ||
            { echo "FAIL: protected MCP runtime assets missing" >&2; exit 1; }
    ' || { echo "  FAIL: MCP bind-mount preflight" >&2; return 1; }

    note "restarting trusted container on protected runtime configuration"
    qga_exec "$vm" "su - mcp -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u) \
        systemctl --user daemon-reload && systemctl --user restart lab-cnt-mcp'" \
        || { echo "  FAIL: trusted MCP restart"; return 1; }
    fi   # have_ports: quadlet block skipped when ports.env underivable

    # trusted-zone liveness watchdog (rc-11): exit-based recovery cannot
    # see a hang — this timer probes /health and restarts the zone on
    # sustained failure. mcp-owned; `lab` must not reach it.
    changed=$(qga_exec "$vm" "
        if cmp -s /tmp/ensure-watchdog \
                  /home/mcp/.local/sbin/labloop-mcp-watchdog 2>/dev/null &&
           cmp -s /tmp/ensure-watchdog.service \
                  /home/mcp/.config/systemd/user/labloop-mcp-watchdog.service \
                  2>/dev/null &&
           cmp -s /tmp/ensure-watchdog.timer \
                  /home/mcp/.config/systemd/user/labloop-mcp-watchdog.timer \
                  2>/dev/null &&
           $ports_cmp 2>/dev/null &&
           su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
               systemctl --user is-enabled --quiet labloop-mcp-watchdog.timer' \
               >/dev/null 2>&1; then
            echo same
        else echo changed; fi" | tr -d '[:space:]')
    if [ "$changed" = changed ]; then
        note "watchdog missing/drifted — installing + enabling as mcp"
        qga_exec "$vm" "
            install -d -m 0755 -o mcp -g mcp /home/mcp/.local/sbin \
                /home/mcp/.local/state/labloop \
                /home/mcp/.config/systemd/user /home/mcp/.config/labloop &&
            $ports_inst &&
            install -m 0755 -o mcp -g mcp /tmp/ensure-watchdog \
                /home/mcp/.local/sbin/labloop-mcp-watchdog &&
            install -m 0644 -o mcp -g mcp /tmp/ensure-watchdog.service \
                /home/mcp/.config/systemd/user/labloop-mcp-watchdog.service &&
            install -m 0644 -o mcp -g mcp /tmp/ensure-watchdog.timer \
                /home/mcp/.config/systemd/user/labloop-mcp-watchdog.timer &&
            su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
                systemctl --user daemon-reload &&
                systemctl --user enable --now labloop-mcp-watchdog.timer'" \
            || echo "  warn: watchdog install/enable failed"
    else
        echo "  watchdog already current + enabled"
    fi

    # trial interpreter env: /srv/lab/trial-env is volume-mounted at
    # /opt/trial-env inside lab-cnt-mcp — episteme's executor default
    # interpreter when populated (entrypoint exports
    # ML_EPISTEME_EXECUTOR_PYTHON). Populate once via podman exec —
    # writes go through the mount to the mcp-owned host dir, so the env
    # survives container recreates. Restart after populate so the
    # entrypoint picks it up.
    # the check must run INSIDE lab-cnt-mcp: the venv's bin/python is a
    # symlink to the container interpreter (/usr/local/bin/python3),
    # which dangles on the host — a host-side test -x always fails and
    # repopulating then dies on 'venv already exists'. Import a marker
    # package too: a bare venv (venv created, packages never installed)
    # must count as unpopulated.
    if ! qga_exec "$vm" "su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
            podman exec lab-cnt-mcp /opt/trial-env/bin/python -c \"import numpy\"'" \
            >/dev/null 2>&1; then
        note "populating /srv/lab/trial-env (uv venv + scientific stack)"
        qga_exec "$vm" "
            install -d -m 0755 -o mcp -g mcp /srv/lab/trial-env &&
            su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
                systemctl --user restart lab-cnt-mcp' &&
            sleep 5 &&
            su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
                podman exec lab-cnt-mcp sh -c \"
                    test -x /opt/trial-env/bin/python ||
                    uv venv /opt/trial-env\"' &&
            su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
                podman exec lab-cnt-mcp uv pip install \
                    --python /opt/trial-env/bin/python --no-cache \
                    numpy pandas scipy scikit-learn matplotlib reportlab' &&
            su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
                systemctl --user restart lab-cnt-mcp'" \
            || echo "  warn: trial-env population failed (egress? mcp container up?)"
    else
        echo "  trial-env already populated"
    fi
    if [ "$exp_quadlet_failed" = 1 ]; then
        echo "  FAIL: trusted MCP update completed, but hostile-zone Quadlet needs repair" >&2
        return 1
    fi
    echo "  done: $vm has extraction (labloop-export) + ingest (/incoming)"
}

if [ "$TARGET" = all ]; then
    for vm in $(virsh -c qemu:///system list --name | grep '^lab-vm-' || true); do
        ensure_vm "$vm"
    done
else
    ensure_vm "$TARGET"
fi
