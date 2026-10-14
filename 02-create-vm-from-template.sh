e
    gio set "$f" metadata::trusted true 2>/dev/null
    set -- $(sha256sum "$f" 2>/dev/null)
    gio set "$f" metadata::xfce-exe-checksum "$1" 2>/dev/null
done
stamp=$(cat "$HOME/.config/lab-pw-stamp" 2>/dev/null)
set -- $(passwd -S "$USER" 2>/dev/null); lastchg=$3
if [ -n "$stamp" ] && [ "$lastchg" != "$stamp" ]; then
    rm -f "$HOME/.config/autostart/lab-first-login.desktop" "$HOME/.config/lab-pw-stamp"
    exit 0
fi
echo "Please set a new login password (current password is your OTP)."
echo
until passwd; do
    echo
    echo "-- password not changed (wrong current password, or too short)."
    echo "   Try again, or close this window to skip for now."
    echo
done
rm -f "$HOME/.config/autostart/lab-first-login.desktop" "$HOME/.config/lab-pw-stamp"
echo
echo "Password changed — this prompt will not appear again."
sleep 3
FIRSTLOGIN
cat > "$WORK/lab-first-login.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Set lab password
Exec=x-terminal-emulator -e /usr/local/bin/lab-first-login
X-GNOME-Autostart-enabled=true
DESKTOP
qga_push "$WORK/lab-first-login" /usr/local/bin/lab-first-login \
    || die "could not upload first-login script"
qga_push "$WORK/lab-first-login.desktop" /home/lab/.config/autostart/lab-first-login.desktop \
    || die "could not upload first-login autostart"
qga 'chmod 0755 /usr/local/bin/lab-first-login &&
     mkdir -p /home/lab/.config/autostart &&
     set -- $(passwd -S lab) &&
     test "$2" = P &&
     printf "%s\n" "$3" > /home/lab/.config/lab-pw-stamp &&
     chown lab:lab /home/lab/.config/autostart/lab-first-login.desktop /home/lab/.config/lab-pw-stamp' \
    || die "could not enable first-login password-change prompt"

note "per-clone agent identity: wipe opencode/vscodium state"
# opencode.db carries session/device identity — every clone must start
# fresh (belt-and-suspenders: 01's sysprep wipes it too, but this also
# covers clones from templates sealed before that change).
qga "rm -rf /home/lab/.local/share/opencode /home/lab/.cache/opencode \
     /home/lab/.config/VSCodium/machineid /home/lab/.cache/sessions"
# .cache/sessions: xfce saves session state there — a stale saved
# session from the template restores ghost apps and can crash the
# first login.

note "waiting for zone containers"
# lab-cnt-mcp runs under the mcp service account — invisible to lab's
# systemctl; probe its published health port instead.
for _ in $(seq 30); do
    qga_lab "curl -m3 -sf http://127.0.0.1:28080/health >/dev/null" 2>/dev/null && break
    sleep 5
done

note "ensuring current tooling (labloop-export, /incoming, batteries)"
# clones from a template built before a tooling change carry the old
# stack — idempotent, so harmless on current templates too
"$(dirname "$0")/30-ensure-lab-tools.sh" "$vm" \
    || echo "warn: ensure step failed — run ./30-ensure-lab-tools.sh $vm manually"

note "check-lab-ready.sh inside $vm"
set +e
qga_lab "bash /home/lab/Desktop/check-lab-ready.sh" </dev/null
rc=$?
set -e

cat <<EOF

==> $vm is up (hostname $vm).

    FIRST LOGIN:  user 'lab' password is $tmp_pw
    — a terminal pops up asking you to set a new one
      (type '$tmp_pw' once as the current password, then your new one).
      also stored at $img_dir/$vm.otp (mode 400)
    (exp is locked — it is a service account, not a login.)

    Open it in virt-manager, or rerun the check inside:
      bash ~/Desktop/check-lab-ready.sh
EOF
exit "$rc"
# Use the maintained QGA driver, including a real ping, transport retries,
# durable execution results, and reliable file upload.
REPO="$(cd "$(dirname "$0")" && pwd)"
QGA_DRIVER="$REPO/scripts/qga.py"
[ -f "$QGA_DRIVER" ] || die "missing $QGA_DRIVER"
qga()      { python3 "$QGA_DRIVER" "$vm" exec "$@"; }
qga_lab()  { python3 "$QGA_DRIVER" "$vm" exec --as lab "$@"; }
qga_push() { python3 "$QGA_DRIVER" "$vm" push "$@"; }
agent_ready() { python3 "$QGA_DRIVER" "$vm" ping >/dev/null 2>&1; }
 $(passwd -S lab) &&
     test "$2" = P &&
     printf "%s\n" "$3" > /home/lab/.config/lab-pw-stamp &&
     chown lab:lab /home/lab/.config/autostart/lab-first-login.desktop /home/lab/.config/lab-pw-stamp' \
    || die "could not enable first-login password-change prompt"

note "per-clone agent identity: wipe opencode/vscodium state"
# opencode.db carries session/device identity — every clone must start
# fresh (belt-and-suspenders: 01's sysprep wipes it too, but this also
# covers clones from templates sealed before that change).
qga "rm -rf /home/lab/.local/share/opencode /home/lab/.cache/opencode \
     /home/lab/.config/VSCodium/machineid /home/lab/.cache/sessions"
# .cache/sessions: xfce saves session state there — a stale saved
# session from the template restores ghost apps and can crash the
# first login.

note "waiting for zone containers"
# lab-cnt-mcp runs under the mcp service account — invisible to lab's
# systemctl; probe its published health port instead.
for _ in $(seq 30); do
    qga_lab "curl -m3 -sf http://127.0.0.1:28080/health >/dev/null" 2>/dev/null && break
    sleep 5
done

note "ensuring current tooling (labloop-export, /incoming, batteries)"
# clones from a template built before a tooling change carry the old
# stack — idempotent, so harmless on current templates too
"$(dirname "$0")/30-ensure-lab-tools.sh" "$vm" \
    || echo "warn: ensure step failed — run ./30-ensure-lab-tools.sh $vm manually"

note "check-lab-ready.sh inside $vm"
set +e
qga_lab "bash /home/lab/Desktop/check-lab-ready.sh" </dev/null
rc=$?
set -e

cat <<EOF

==> $vm is up (hostname $vm).

    FIRST LOGIN:  user 'lab' password is $tmp_pw
    — a terminal pops up asking you to set a new one
      (type '$tmp_pw' once as the current password, then your new one).
      also stored at $img_dir/$vm.otp (mode 400)
    (exp is locked — it is a service account, not a login.)

    Open it in virt-manager, or rerun the check inside:
      bash ~/Desktop/check-lab-ready.sh
EOF
exit "$rc"
