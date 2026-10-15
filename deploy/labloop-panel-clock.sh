#!/usr/bin/env bash
# Reinstate the explicit UTC label in XFCE's panel clock each login.
# Never mark complete when no session/plugin is available.
set -euo pipefail
export DISPLAY="${DISPLAY:-:0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"

# Look up the clock plugin by exact module name, not a guessed ID.
plugin=""
kind=""
for _ in $(seq 30); do
    record="$(xfconf-query -c xfce4-panel -lv 2>/dev/null |
        awk '$1 ~ /^\/plugins\/plugin-[0-9]+$/ && ($2 == "clock" || $2 == "datetime") {
            print $1 " " $2; exit
        }' || true)"
    if [ -n "$record" ]; then
        plugin="${record%% *}"
        kind="${record#* }"
        break
    fi
    sleep 1
done
if [ -z "$plugin" ]; then
    echo "UTC clock: no XFCE clock/datetime plugin is registered" >&2
    exit 1
fi

set_property() {
    # Bash expands RHS of a multi-name local declaration before it assigns
    # any of those names. With set -u, referencing $key here used to abort.
    local key="$1" value="$2"
    local property="$plugin/$key"
    if ! xfconf-query -c xfce4-panel -p "$property" -s "$value" 2>/dev/null; then
        xfconf-query -c xfce4-panel -p "$property" --create -t string -s "$value"
    fi
    test "$(xfconf-query -c xfce4-panel -p "$property")" = "$value"
}
set_property timezone UTC
# XFCE classic digital clock reads digital-time-format; datetime reads
# time-format. A literal UTC suffix is deliberate, not host-local %Z.
if [ "$kind" = datetime ]; then
    set_property time-format '%H:%M UTC'
else
    set_property digital-time-format '%H:%M UTC'
fi
echo "UTC clock: applied %H:%M UTC to $plugin ($kind)"
