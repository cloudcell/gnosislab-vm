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
for a in "$@"; do
    [ "$a" = "--rebuild-mcp-image" ] && REBUILD_IMAGE=1
done
TARGET=${1:?"usage: ./30-ensure-lab-tools.sh <vm>|all [--rebuild-mcp-image]"}
id -nG | grep -qw libvirt || exec sg libvirt -c "$0 $*"

# labloop.conf carries the display target too — the ensure path renders
# /etc/labloop/display.conf for the guest's login hook from it.
if [ -f "$REPO/labloop.conf" ]; then . "$REPO/labloop.conf"; fi
RES_X="${LABLOOP_RES_X:-2560}"
RES_Y="${LABLOOP_RES_Y:-1440}"
REFRESH="${LABLOOP_REFRESH:-75}"
printf 'RES_X=%s\nRES_Y=%s\nREFRESH=%s\n' "$RES_X" "$RES_Y" "$REFRESH" \
    > "$WORK/display.conf"

# ------------------------------------------------------------------
# qemu guest-agent driver (exec + push)
# ------------------------------------------------------------------
cat > "$WORK/qga.py" <<'PYEOF'
import base64, json, subprocess, sys, time
dom, mode, args = sys.argv[1], sys.argv[2], sys.argv[3:]
def qga(payload):
    try:
        r = subprocess.run(["virsh","-c","qemu:///system","qemu-agent-command",
                            dom, json.dumps(payload)],
                           capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        sys.stderr.write((e.stderr or "") + (e.stdout or ""))
        sys.exit(2)   # transport-level failure — caller may retry
    return json.loads(r.stdout)["return"]
if mode == "exec":
    pid = qga({"execute":"guest-exec","arguments":
               {"path":"/bin/sh","arg":["-c"," ".join(args)],
                "capture-output":True}})["pid"]
    for _ in range(600):
        time.sleep(0.5)
        st = qga({"execute":"guest-exec-status","arguments":{"pid":pid}})
        if st.get("exited"):
            sys.stdout.write(base64.b64decode(
                st.get("out-data","") or "").decode("utf-8","replace"))
            sys.stderr.write(base64.b64decode(
                st.get("err-data","") or "").decode("utf-8","replace"))
            sys.exit(st.get("exitcode",1))
    sys.exit("guest-exec timeout")
if mode == "push":
    local, remote = args
    h = qga({"execute":"guest-file-open","arguments":{"path":remote,"mode":"w+"}})
    try:
        with open(local,"rb") as f:
            while chunk := f.read(48*1024):
                qga({"execute":"guest-file-write","arguments":
                     {"handle":h,"buf-b64":base64.b64encode(chunk).decode()}})
    finally:
        qga({"execute":"guest-file-close","arguments":{"handle":h}})
PYEOF

# transport hiccups (agent up but exec/file-open briefly refused — seen
# right after boot or when /run was full) get retried; a genuine
# in-guest exit code does not
qga_exec() {
    local vm=$1 rc=0 _; shift
    for _ in 1 2 3 4 5; do
        python3 "$WORK/qga.py" "$vm" exec "$@" && return 0 || rc=$?
        [ "$rc" -eq 2 ] || return "$rc"
        sleep 4
    done
    return 2
}
qga_push() {
    local vm=$1 rc=0 _; shift
    for _ in 1 2 3 4 5; do
        python3 "$WORK/qga.py" "$vm" push "$@" && return 0 || rc=$?
        [ "$rc" -eq 2 ] || return "$rc"
        sleep 4
    done
    return 2
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
    note "restarting lab-cnt-mcp on rebuilt image"
    qga_exec "$vm" "su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
        systemctl --user restart lab-cnt-mcp'" \
        || { echo "  FAIL: restart"; return 1; }
    echo "  image rebuilt + zone restarted"
}

ensure_vm() {
    local vm=$1
    echo; echo "### $vm"
    virsh -c qemu:///system list --name | grep -qx "$vm" \
        || { echo "  skip: not running"; return 0; }
    qga_exec "$vm" "id -u" >/dev/null 2>&1 \
        || { echo "  skip: guest-agent not answering"; return 0; }

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
             opencode.json opencode.jsonc; do
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
        rebuild_mcp_image "$vm" || echo "  warn: image rebuild failed"
    fi

    # ports.env derives from the VM's OWN lab-img-mcp image — never the
    # repo: the render must match the vintage actually installed
    # (/opt/gnosislab on packaged images, /opt/ml-scientist on
    # pre-switch ones — the glob covers both). From the image, not
    # `podman exec`: the watchdog needs it when the container is down.
    # Fallback is the VM's installed copy — equally vintage-true.
    local ports_env_txt
    ports_env_txt=$(qga_exec "$vm" "su - mcp -c 'podman run --rm \
        --entrypoint sh lab-img-mcp -c \"cat /opt/*/ports.env\"'" \
        2>/dev/null | sed -n '/^ML_/p' || true)
    if [ -z "$ports_env_txt" ]; then
        ports_env_txt=$(qga_exec "$vm" \
            "cat /home/mcp/.config/labloop/ports.env 2>/dev/null" || true)
    fi
    local have_ports=0
    if [ -n "$ports_env_txt" ]; then
        have_ports=1
        printf '%s\n' "$ports_env_txt" > "$WORK/ports.env"
        case "$ports_env_txt" in
            *ML_AGORA_PORT=38*)
                echo "  note: image is 38xxx-vintage — run --rebuild-mcp-image to migrate to gnosislab/28xxx" ;;
        esac
        # render the mcp quadlet's publish block — the file is a
        # template (@MCP_PORTS_PUBLISH@); verbatim push would leave an
        # unexpanded placeholder in the guest's quadlet.
        ( set -a; . "$WORK/ports.env"; set +a
          grep -oE '^ML_[A-Z_]+_PORT' "$WORK/ports.env" \
              | while read -r v; do
                    printf 'PublishPort=127.0.0.1:%s:%s\n' "${!v}" "${!v}"
                done ) > "$WORK/mcp-ports.publish"
    else
        echo "  warn: cannot derive ports.env (no image, no installed copy) — mcp quadlet/ports push skipped"
        : > "$WORK/mcp-ports.publish"
    fi
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
        cmp -s /tmp/ensure-opencode.json \
               /home/lab/.config/opencode/opencode.json &&
        cmp -s /tmp/ensure-opencode.jsonc \
               /home/lab/.config/opencode/opencode.jsonc &&
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
        su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
            systemctl --user is-enabled --quiet labloop-mcp-watchdog.timer' \
            >/dev/null 2>&1 &&
        su - mcp -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u);
            podman exec lab-cnt-mcp /opt/trial-env/bin/python -c \"import numpy\"' \
            >/dev/null 2>&1$diag_cmp" >/dev/null 2>&1 || need=1
    [ "$need" = 0 ] && [ "$REBUILD_IMAGE" = 0 ] \
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
        install -m 0755 -o root -g root /tmp/ensure-labloop-display.sh \
            /usr/local/libexec/labloop-display.sh &&
        install -m 0644 -o root -g root /tmp/ensure-labloop-display.desktop \
            /etc/xdg/autostart/labloop-display.desktop &&
        install -d -m 0755 /etc/lightdm/lightdm.conf.d &&
        install -m 0644 -o root -g root \
            /tmp/ensure-labloop-display-lightdm.conf \
            /etc/lightdm/lightdm.conf.d/50-labloop-display.conf &&
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
        install -d -m 0755 -o lab -g lab /home/lab/.config/opencode &&
        install -m 0644 -o lab -g lab /tmp/ensure-opencode.json \
            /home/lab/.config/opencode/opencode.json &&
        install -m 0644 -o lab -g lab /tmp/ensure-opencode.jsonc \
            /home/lab/.config/opencode/opencode.jsonc &&
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

    # quadlet: update definition; restart lab-cnt-exp only if it changed
    local changed
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
            || echo "  warn: quadlet install/restart failed"
    else
        echo "  quadlet already current"
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
    echo "  done: $vm has extraction (labloop-export) + ingest (/incoming)"
}

if [ "$TARGET" = all ]; then
    for vm in $(virsh -c qemu:///system list --name | grep '^lab-vm-' || true); do
        ensure_vm "$vm"
    done
else
    ensure_vm "$TARGET"
fi
