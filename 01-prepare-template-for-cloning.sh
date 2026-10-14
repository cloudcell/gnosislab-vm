#!/usr/bin/env bash
# 01-prepare-template-for-cloning.sh — seal the golden template.
#
#   1. (optional, public images) LABLOOP_PUBLISH=1 locks lab+exp
#      passwords inside the guest BEFORE scrubbing — mandatory if
#      the qcow2 will ever leave this host: the hash is
#      offline-crackable by anyone who downloads it.
#   2. shut the template down if it is running
#   3. sudo virt-sysprep — scrub machine-id, ssh keys, hostname, logs
#   4. snp-vN snapshot of the sealed state
#
# After this, clones come from 02-create-vm-from-template.sh.
# Asks for your sudo password where required — run in a terminal.
set -euo pipefail

VIRSH="virsh -c qemu:///system"
WORK="$(mktemp -d)"
trap 'report_phases 2>/dev/null; rm -rf "$WORK"' EXIT

die()  { echo "01-prepare: $*" >&2; exit 1; }
# phase timing — each note() call closes the previous phase; the EXIT
# trap prints the breakdown + total elapsed
T0=$SECONDS; _pt=$T0
PHASE_NAMES=() PHASE_SECS=()
note() {
    local now=$SECONDS
    ((${#PHASE_NAMES[@]})) && PHASE_SECS+=("$((now - _pt))")
    PHASE_NAMES+=("$*"); _pt=$now
    echo; echo "==> $*"
}
_fmt_dur() { printf '%dm%02ds' $(($1/60)) $(($1%60)); }
report_phases() {
    local now=$SECONDS i
    ((${#PHASE_NAMES[@]})) || return 0
    PHASE_SECS+=("$((now - _pt))")
    echo; echo "==> phases:"
    for i in "${!PHASE_NAMES[@]}"; do
        printf '    %-56s %7s\n' "${PHASE_NAMES[$i]}" "$(_fmt_dur "${PHASE_SECS[$i]}")"
    done
    printf '    %-56s %7s\n' TOTAL "$(_fmt_dur $((now - T0)))"
}

# default template: newest lab-template-<UTC-ts>; fall back to any
# lab-template-* (e.g. lab-template-v1) when no dated build exists
pick_template() {
    local names ts
    names="$($VIRSH list --all --name 2>/dev/null | grep '^lab-template-' || true)"
    ts="$(grep -E '^lab-template-[0-9]{8}T[0-9]{4}Z$' <<<"$names" | sort | tail -n1)"
    [ -n "$ts" ] && { echo "$ts"; return; }
    tail -n1 <<<"$names"
}

id -nG | grep -qw libvirt || exec sg libvirt -c "$0 $*"
VM="${1:-$(pick_template)}"
[ -n "$VM" ] || die "no lab-template-* domain found — build one with ./00-build-lab-template.sh"
$VIRSH dominfo "$VM" >/dev/null 2>&1 || die "domain '$VM' not found"
note "template: $VM"

# prime sudo NOW — the privileged call (virt-sysprep) comes after a
# long shutdown wait; ask the password up front so the rest is
# hands-off. Keepalive refreshes the timestamp for the whole run.
sudo -v
(for _ in $(seq 60); do sudo -n true 2>/dev/null || break; sleep 60; done) &
SUDO_KEEPALIVE=$!
trap 'report_phases; kill "$SUDO_KEEPALIVE" 2>/dev/null; rm -rf "$WORK"' EXIT

# Shared driver checks the actual guest-ping response and preserves results.
QGA_DRIVER="$(cd "$(dirname "$0")" && pwd)/scripts/qga.py"
[ -f "$QGA_DRIVER" ] || die "missing $QGA_DRIVER"

agent_ready() { python3 "$QGA_DRIVER" "$VM" ping >/dev/null 2>&1; }
qga()       { python3 "$QGA_DRIVER" "$VM" exec "$@"; }

running()   { [ "$($VIRSH domstate "$VM" 2>/dev/null)" != "shut off" ]; }

shutdown_vm() {
    note "shutting down $VM"
    qga systemctl poweroff 2>/dev/null || $VIRSH shutdown "$VM" >/dev/null 2>&1 || true
    for _ in $(seq 36); do running || break; sleep 5; done
    # must end true on success: shutdown_vm is the last command of a
    # && list at the call site, so a false status here trips set -e
    ! running || die "$VM did not shut down"
}

# ------------------------------------------------------------------
# 1. publish mode — needs a running guest (lock happens inside)
# ------------------------------------------------------------------
if [ "${LABLOOP_PUBLISH:-0}" = "1" ]; then
    if ! running; then
        note "PUBLISH mode: booting $VM to lock passwords"
        $VIRSH start "$VM" >/dev/null
        for _ in $(seq 36); do agent_ready && break; sleep 5; done
        agent_ready || die "guest agent never came up"
        # guest-ping answers before guest-exec is usable — warm it up
        for _ in $(seq 24); do qga true 2>/dev/null && break; sleep 5; done
        qga true 2>/dev/null || die "guest-exec not usable in $VM"
    fi
    note "locking lab+exp+mcp passwords (public-image policy)"
    qga "passwd -l lab && passwd -l exp && passwd -l mcp 2>/dev/null; \
         passwd -S lab | grep -q ' L ' && passwd -S exp | grep -q ' L '"
fi

# ------------------------------------------------------------------
# 2. shut down
# ------------------------------------------------------------------
running && shutdown_vm

# ------------------------------------------------------------------
# 3. scrub identity
# ------------------------------------------------------------------
note "virt-sysprep $VM"
# --run-command: wipe per-instance agent state so every clone gets a
# fresh opencode identity (opencode.db carries session/device state);
# VSCodium machineid is regenerated on first launch. rm -rf is safe on
# missing paths, unlike --delete.
sudo virt-sysprep -d "$VM" \
    --run-command 'rm -rf /home/lab/.local/share/opencode /home/lab/.cache/opencode /home/lab/.config/VSCodium/machineid /home/lab/.cache/sessions /var/tmp/gnosislab-qga-*'

# ------------------------------------------------------------------
# 4. snapshot the sealed state — snp-vN continues pre-freeze numbering
# ------------------------------------------------------------------
next=$($VIRSH snapshot-list --name "$VM" 2>/dev/null | \
       sed -n 's/^.*-\{0,1\}v\([0-9]\+\)$/\1/p' | sort -n | tail -1)
snap="snp-v$(( ${next:-0} + 1 ))"
$VIRSH snapshot-create-as "$VM" "$snap" "sealed by 01-prepare-template-for-cloning"

cat <<EOF

==> $VM sealed as $snap${LABLOOP_PUBLISH:+, passwords locked (publish mode)}.

    Next: ./02-create-vm-from-template.sh <owner>
EOF
