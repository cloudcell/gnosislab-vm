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
    /home/lab/.local/share/icons /home/lab/.local/share/applications'

# Host files, not /srv/lab/workspace (agent-writable).
push "$REPO/deploy/check-lab-ready.sh" /home/lab/Desktop/check-lab-ready.sh
push "$REPO/deploy/Lab-Dashboard.desktop" /home/lab/Desktop/Lab-Dashboard.desktop
push "$REPO/deploy/Desktop-README.md" /home/lab/Desktop/README.md
push "$REPO/deploy/opencode.desktop" /home/lab/Desktop/opencode.desktop
push "$REPO/deploy/opencode.desktop" /home/lab/.local/share/applications/opencode.desktop
push "$REPO/assets/opencode-wordmark-dark.png" /home/lab/.local/share/icons/opencode.png
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
echo "  desktop restored for $vm (Dashboard, OpenCode, README, readiness check)"
