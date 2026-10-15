#!/usr/bin/env bash
# check-lab-ready.sh — is this lab VM ready to work?
# Runs on the driver desktop as `lab`. Double-click from ~/Desktop or
# run in a shell. PASS/FAIL per check, then the full security battery.

# Double-clicked without a terminal? Re-exec inside one so the output
# is visible. Guarded on $DISPLAY so provisioning/qga (headless) still
# runs it in-process.
if [ -n "${DISPLAY:-}" ] && [ ! -t 0 ] && [ -z "${_LABREADY_TTY:-}" ]; then
    export _LABREADY_TTY=1
    exec x-terminal-emulator -e bash "$0" "$@"
fi

set -u
pass=0; fail=0; warn=0
ok()   { printf 'PASS  %-34s %s\n' "$1" "$2"; pass=$((pass+1)); }
warn() { printf 'WARN  %-34s %s\n' "$1" "$2"; warn=$((warn+1)); }
bad()  { printf 'FAIL  %-34s %s\n' "$1" "$2"; fail=$((fail+1)); }

echo "== lab readiness check =="

# Fresh boot? Quadlets take a while — wait for both zones before
# checking, so an early run doesn't report false FAILs.
# lab-cnt-mcp runs under the `mcp` service account — lab's systemctl
# cannot see it; probe the published health port instead.
waited=0
until curl -m3 -sf http://127.0.0.1:28080/health >/dev/null 2>&1 \
   && sudo -n -u exp /usr/local/sbin/labloop-exec true 2>/dev/null; do
    [ "$waited" -ge 300 ] && break
    [ $((waited % 30)) -eq 0 ] && [ "$waited" -gt 0 ] \
        && echo "    ... waiting for zone containers (${waited}s)"
    sleep 5; waited=$((waited+5))
done

# --- zones up ----------------------------------------------------------
if pgrep -u mcp -f 'labloop-mcp' >/dev/null 2>&1; then
    ok trusted-container "lab-cnt-mcp active (under mcp service account)"
else
    bad trusted-container "lab-cnt-mcp down — runs under mcp; check 28080 /health"
fi

if sudo -n -u exp /usr/local/sbin/labloop-exec true 2>/dev/null; then
    ok exec-channel "lab -> lab-cnt-exp via labloop-exec"
else
    bad exec-channel "cannot reach lab-cnt-exp — is exp's unit up?"
fi

# --- MCP surfaces ------------------------------------------------------
for p in 28050 28060 28070 28080 28082 28090; do
    if curl -m3 -sf "http://127.0.0.1:$p/health" >/dev/null 2>&1; then
        ok "port-$p" "/health ok"
    else
        bad "port-$p" "no /health on 127.0.0.1:$p"
    fi
done

# --- driver tooling ----------------------------------------------------
for tool in opencode uv uvx codium git mc; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "tool-$tool" "$(command -v "$tool")"
    else
        bad "tool-$tool" "not on PATH"
    fi
done

# --- agent configs -----------------------------------------------------
OC=~/.config/opencode/opencode.json
if [ -f "$OC" ] && grep -q '"episteme"' "$OC"; then
    ok opencode-config "MCP servers wired in opencode.json"
else
    bad opencode-config "$OC missing or no MCP servers"
fi
OCC=~/.config/opencode/opencode.jsonc
if [ -f "$OCC" ] && grep -Eq '"host-local"|"vllm"' "$OCC"; then
    ok opencode-local "host-local model provider configured"
else
    warn opencode-local "configure with ~/Desktop/optional-patches/configure-host-models.py"
fi
if curl --max-time 3 -fsS http://192.168.122.1:8002/v1/models >/dev/null 2>&1; then
    ok host-llm "host LLM reachable on default endpoint"
else
    warn host-llm "default host endpoint unavailable (may use custom endpoint)"
fi
# V2 updater detects the curl installation only when the running ELF
# lives at /home/lab/.opencode/bin/opencode; the system entry is a
# root-owned launcher, not the executable it runs.
OCBIN="$(command -v opencode 2>/dev/null || true)"
USERBIN=/home/lab/.opencode/bin/opencode
if [ ! -f "$USERBIN" ] || [ -L "$USERBIN" ] || [ ! -x "$USERBIN" ]; then
    bad opencode-updater "user-local V2 executable absent or unsafe"
elif [ "$(stat -c %U "$USERBIN" 2>/dev/null)" != lab ]; then
    bad opencode-updater "OpenCode executable must be lab-owned"
elif [ "$(head -c 4 "$USERBIN" | od -An -tx1 | tr -d '[:space:]')" != 7f454c46 ]; then
    bad opencode-updater "user-local executable is not an ELF binary"
elif [ "$OCBIN" != /usr/local/bin/opencode ]; then
    warn opencode-updater "$OCBIN shadows managed launcher"
elif [ ! -x /usr/local/bin/opencode ]; then
    bad opencode-updater "launcher missing"
elif ! version=$("$USERBIN" --version 2>/dev/null); then
    bad opencode-updater "user-local OpenCode executable failed to report its version"
elif ! printf '%s\\n' "$version" | grep -Eq '^((opencode[[:space:]]+)?v?2[.][0-9]+[.][0-9]+)'; then
    bad opencode-updater "unexpected V2 version format: $version"
elif ! launcher_version=$(/usr/local/bin/opencode --version 2>/dev/null); then
    bad opencode-updater "system launcher failed to report its version"
elif [ "$version" != "$launcher_version" ]; then
    bad opencode-updater "launcher version $launcher_version differs from direct version $version"
else
    ok opencode-updater "lab-owned OpenCode $version; launcher matches"
fi

ZC=~/.config/VSCodium/User/globalStorage/zoocodeorganization.zoo-code/settings/mcp_settings.json
if [ -f "$ZC" ]; then
    ok zoo-config "zoo-code mcp_settings.json present"
else
    bad zoo-config "zoo-code MCP settings missing"
fi

# --- trust-boundary layout ---------------------------------------------
for d in /srv/lab/workspace /srv/lab/exchange /srv/lab/experiments \
         /srv/lab/mcp-state "$HOME/workspace/experiments"; do
    [ -d "$d" ] && ok "dir:$(basename "$d")" "$d" \
                || bad "dir:$(basename "$d")" "$d missing"
done

# trial interpreter env: episteme's executor uses /opt/trial-env
# (mounted from /srv/lab/trial-env) when populated — without it trials
# run on the slim server venv and numpy imports fail. WARN not FAIL:
# the env is supplementary, old clones degrade gracefully.
# NOTE: bin/python is a symlink to the container-internal interpreter
# (/usr/local/bin/python3) — dangling from the host's view, so test -x
# on it is permanently false. Check a real installed package instead.
set -- /srv/lab/trial-env/lib/python*/site-packages/numpy/__init__.py
if [ -f "$1" ]; then
    ok dir:trial-env "/srv/lab/trial-env -> /opt/trial-env (scientific stack for trials)"
else
    warn dir:trial-env "/srv/lab/trial-env unpopulated — trials lack numpy/scipy stack"
fi

# --- display status -----------------------------------------------------
# SPICE/virtio determines the active resolution. Headless QGA checks
# cannot measure XRandR; report SKIP rather than a misleading warning.
# A live desktop should be visible and functional, irrespective of Hz.
if [ -e /etc/lightdm/lightdm.conf.d/50-labloop-display.conf ] ||
   [ -e /etc/xdg/autostart/labloop-display.desktop ]; then
    bad display-hook "obsolete forced XRandR hook present (black-screen risk)"
elif [ -z "${DISPLAY:-}" ]; then
    printf 'SKIP  %-34s %s\n' display-mode "headless; graphical session not present"
elif ! command -v xrandr >/dev/null 2>&1; then
    bad display-mode "xrandr unavailable in graphical session"
else
    xr="$(xrandr 2>/dev/null)" || xr=""
    if printf '%s\n' "$xr" | grep -qE ' connected'; then
        current="$(printf '%s\n' "$xr" | sed -n 's/.*current \([0-9]* x [0-9]*\).*/\1/p')"
        ok display-mode "connected graphical display ${current:-detected}; SPICE-managed"
    else
        bad display-mode "no connected graphical output reported by xrandr"
    fi
fi

echo
echo "== $pass PASS, $warn WARN, $fail FAIL =="

# --- deep checks: security + functional batteries ----------------------
sec=/srv/lab/workspace/ml-labloop/deploy/security-battery.sh
fun=/srv/lab/workspace/ml-labloop/deploy/functional-battery.sh
if [ "$fail" -eq 0 ] && [ -f "$sec" ]; then
    echo "== security battery =="
    bash "$sec"
fi
if [ "$fail" -eq 0 ] && [ -f "$fun" ]; then
    echo "== functional battery =="
    bash "$fun"
fi

# keep the terminal open when double-clicked
[ -t 0 ] && { echo; read -r -p "press enter to close"; }
exit "$fail"
