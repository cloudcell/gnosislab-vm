#!/usr/bin/env bash
# Restore standard VM desktop from trusted host checkout; preserve custom files.
# Usage: bash scripts/ensure-vm-desktop.sh lab-vm-<name>
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$REPO/scripts/qga.py"
vm="${1:?usage: ensure-vm-desktop.sh lab-vm-<name>}"
case "$vm" in
    lab-vm-*) ;;
    *) echo "expected a lab-vm-* domain: $vm" >&2; exit 2 ;;
esac
case "$vm" in *[!a-z0-9-]*|lab-vm-)
    echo "invalid VM name: $vm" >&2; exit 2 ;; esac
[ -f "$DRIVER" ] || { echo "missing $DRIVER" >&2; exit 1; }
qga() { python3 "$DRIVER" "$vm" exec "$@"; }
push() { python3 "$DRIVER" "$vm" push "$1" "$2"; }
python3 "$DRIVER" "$vm" ping >/dev/null ||
    { echo "guest agent unavailable: $vm" >&2; exit 1; }

qga 'install -d -m 0755 -o lab -g lab /home/lab/Desktop \
    /home/lab/.local/share/icons /home/lab/.local/share/applications \
    /home/lab/Desktop/diagnostics /home/lab/Desktop/optional-patches'

# Host files, not /srv/lab/workspace (agent-writable).
push "$REPO/deploy/check-lab-ready.sh" /home/lab/Desktop/check-lab-ready.sh
push "$REPO/deploy/Lab-Dashboard.desktop" /home/lab/Desktop/Lab-Dashboard.desktop
push "$REPO/deploy/Desktop-README.md" /home/lab/Desktop/README.md
push "$REPO/deploy/opencode.desktop" /home/lab/Desktop/opencode.desktop
push "$REPO/deploy/opencode.desktop" /home/lab/.local/share/applications/opencode.desktop
push "$REPO/assets/opencode-wordmark-dark.png" /home/lab/.local/share/icons/opencode.png
# Always ship useful diagnostic scripts and an opt-in local model setup.
for f in security-battery.sh functional-battery.sh; do
    push "$REPO/deploy/$f" "/home/lab/Desktop/diagnostics/$f"
done
push "$REPO/deploy/diagnostics-README.md" /home/lab/Desktop/diagnostics/README.md
push "$REPO/deploy/configure-host-models.py" /home/lab/Desktop/optional-patches/configure-host-models.py
push "$REPO/deploy/optional-patches-README.md" /home/lab/Desktop/optional-patches/README.md

# Additional cached reports (when present) and operator-provided
# private patches are additive. Never infer model IDs or execute patches.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/labloop/pkgs/gnosislab/diagnostics"
if [ -d "$CACHE" ]; then
    for file in "$CACHE"/*; do
        [ -f "$file" ] || continue
        name="$(basename "$file")"
        case "$name" in *[!a-zA-Z0-9._-]* ) continue ;; esac
        push "$file" "/home/lab/Desktop/diagnostics/$name"
    done
fi
if [ -n "${LABLOOP_PATCHES_DIR:-}" ]; then
    [ -d "$LABLOOP_PATCHES_DIR" ] || { echo "patch directory not found" >&2; exit 1; }
    for file in "$LABLOOP_PATCHES_DIR"/*; do
        [ -f "$file" ] || continue
        name="$(basename "$file")"
        case "$name" in *[!a-zA-Z0-9._-]* ) continue ;; esac
        push "$file" "/home/lab/Desktop/optional-patches/$name"
    done
fi

# Trusted copies for session-time checksum comparison. Install through QGA
# into root-owned locations, never from the lab-writable workspace.
qga 'install -d -m 0755 -o root -g root /usr/local/share/gnosislab/desktop /usr/local/libexec /etc/xdg/autostart'
push "$REPO/deploy/opencode.desktop" /usr/local/share/gnosislab/desktop/opencode.desktop
push "$REPO/deploy/Lab-Dashboard.desktop" /usr/local/share/gnosislab/desktop/Lab-Dashboard.desktop
push "$REPO/deploy/gnosislab-desktop-trust.sh" /usr/local/libexec/gnosislab-desktop-trust.sh
push "$REPO/deploy/gnosislab-desktop-trust.desktop" /etc/xdg/autostart/gnosislab-desktop-trust.desktop
qga 'chown root:root /usr/local/share/gnosislab/desktop/*.desktop /usr/local/libexec/gnosislab-desktop-trust.sh /etc/xdg/autostart/gnosislab-desktop-trust.desktop &&
    chmod 0644 /usr/local/share/gnosislab/desktop/*.desktop /etc/xdg/autostart/gnosislab-desktop-trust.desktop &&
    chmod 0755 /usr/local/libexec/gnosislab-desktop-trust.sh'
# If a real GUI session is active, trust now without logout. Otherwise the
# system-wide XDG autostart hook runs in lab's next graphical session.
qga 'if [ -S /run/user/$(id -u lab)/bus ]; then
    su - lab -c "/usr/local/libexec/gnosislab-desktop-trust.sh" || true
fi'

# Install root-owned executable directly, without a lab-writable /tmp stage.
push "$REPO/deploy/opencode-lab" /usr/local/bin/opencode-lab
qga 'set -eu
    chown root:root /usr/local/bin/opencode-lab
    chmod 0755 /usr/local/bin/opencode-lab
    chown lab:lab /home/lab/Desktop/check-lab-ready.sh \
        /home/lab/Desktop/Lab-Dashboard.desktop \
        /home/lab/Desktop/opencode.desktop /home/lab/Desktop/README.md \
        /home/lab/.local/share/applications/opencode.desktop \
        /home/lab/.local/share/icons/opencode.png
    chmod 0755 /home/lab/Desktop/check-lab-ready.sh \
        /home/lab/Desktop/Lab-Dashboard.desktop \
        /home/lab/Desktop/opencode.desktop
    chmod 0644 /home/lab/Desktop/README.md \
        /home/lab/.local/share/applications/opencode.desktop \
        /home/lab/.local/share/icons/opencode.png
    test -s /home/lab/Desktop/Lab-Dashboard.desktop
    test -s /home/lab/Desktop/opencode.desktop
    test -s /home/lab/Desktop/README.md
    test -x /home/lab/Desktop/check-lab-ready.sh
    test -x /usr/local/bin/opencode-lab'
qga 'chown -R lab:lab /home/lab/Desktop/diagnostics /home/lab/Desktop/optional-patches &&
    find /home/lab/Desktop/diagnostics /home/lab/Desktop/optional-patches -type f -name "*.sh" -exec chmod 0755 {} + &&
    chmod 0755 /home/lab/Desktop/optional-patches/configure-host-models.py &&
    test -s /home/lab/Desktop/diagnostics/README.md &&
    test -s /home/lab/Desktop/optional-patches/README.md'
echo "  desktop restored for $vm (Dashboard, OpenCode, README, readiness check)"
