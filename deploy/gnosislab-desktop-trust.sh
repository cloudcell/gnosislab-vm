#!/usr/bin/env bash
# Trust ONLY host-provisioned GnosisLab launchers in the real lab GUI session.
# XFCE requires executable mode AND metadata::xfce-exe-checksum, stored by
# GVFS per user through the login session D-Bus. Root or an isolated
# dbus-run-session cannot write the metadata used by the desktop.
set -euo pipefail

if [ "$(id -un)" != lab ]; then
    echo "gnosislab-desktop-trust: run as lab, not root" >&2
    exit 1
fi
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
    echo "gnosislab-desktop-trust: no lab GUI D-Bus session yet; deferred until login"
    exit 0
fi
command -v gio >/dev/null || { echo "gnosislab-desktop-trust: gio missing" >&2; exit 1; }

failed=0
for name in opencode.desktop Lab-Dashboard.desktop; do
    file="/home/lab/Desktop/$name"
    reference="/usr/local/share/gnosislab/desktop/$name"
    # Never trust arbitrary agent-created launchers. Reference paths and
    # the script are installed root-owned from the trusted host checkout.
    if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -f "$reference" ] ||
       [ -L "$reference" ] || [ "$(stat -c %u "$reference")" != 0 ] ||
       [ "$(stat -c %u /usr/local/share/gnosislab/desktop)" != 0 ] ||
       ! cmp -s "$file" "$reference"; then
        echo "gnosislab-desktop-trust: $name differs from trusted host copy; leaving untrusted" >&2
        failed=1
        continue
    fi
    chmod 0755 "$file"
    checksum="$(sha256sum "$file" | cut -d' ' -f1)"
    # The XFCE value MUST be a string; metadata::trusted is for GNOME.
    # Retry briefly while gvfs-metadata is coming up at first login.
    applied=0
    for _ in 1 2 3 4 5; do
        if gio set -t string "$file" metadata::xfce-exe-checksum "$checksum" 2>/dev/null &&
           gio info -a metadata::xfce-exe-checksum "$file" 2>/dev/null |
             grep -Fq "metadata::xfce-exe-checksum: $checksum"; then
            applied=1
            break
        fi
        sleep 1
    done
    if [ "$applied" != 1 ]; then
        echo "gnosislab-desktop-trust: could not verify $name trust metadata on session bus" >&2
        failed=1
        continue
    fi
    gio set "$file" metadata::trusted true 2>/dev/null || true
    touch "$file"   # notify xfdesktop of updated launcher trust
done
exit "$failed"
