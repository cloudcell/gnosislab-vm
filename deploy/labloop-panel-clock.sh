#!/usr/bin/env bash
# Keep the XFCE panel clock in UTC with the explicit timezone suffix.
# Runs at each graphical login via /etc/xdg/autostart; no one-shot stamp.
# Older clones can run it again in the active lab GUI session.
set -euo pipefail

export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
export DISPLAY="${DISPLAY:-:0}"

# The panel plugin id is assigned dynamically. Wait for xfconfd and
# plugin registration, not an arbitrary fixed panel instance number.
clock_plugin=""
for _ in $(seq 30); do
    clock_plugin="$(xfconf-query -c xfce4-panel -lv 2>/dev/null | awk '
        $1 ~ /^\/plugins\/plugin-[0-9]+$/ && $2 == "clock" || $2 == "datetime" {
            sub(".*/", "", $1); print $1; exit
        }')"
    [ -n "$clock_plugin" ] && break
    sleep 1
done
if [ -z "$clock_plugin" ]; then
    echo "labloop-panel-clock: no XFCE clock plugin found; retry at next login" >&2
    exit 1
fi

# Write live xfconf state, with an explicit UTC label. XFCE plugin builds
# vary: classic clock uses digital-time-format; datetime uses time-format.
# Setting both is harmless and supports both plugin variants.
# Use the plugin-local timezone rather than relying on the host's TZ.
# Create new properties, or update existing ones, then verify both.
for setting in "timezone=UTC" "digital-time-format=%H:%M UTC" "time-format=%H:%M UTC"; do
    property="/plugins/$clock_plugin/${setting%%=*}"
    value="${setting#*=}"
    current="$(xfconf-query -c xfce4-panel -p "$property" 2>/dev/null || true)"
    [ "$current" = "$value" ] && continue
    if ! xfconf-query -c xfce4-panel -p "$property" -s "$value" 2>/dev/null; then
        xfconf-query -c xfce4-panel -p "$property" --create -t string -s "$value"
    fi
    actual="$(xfconf-query -c xfce4-panel -p "$property" 2>/dev/null || true)"
    if [ "$actual" != "$value" ]; then
        echo "labloop-panel-clock: could not apply $property" >&2
        exit 1
    fi
done
# xfconf changes notify the running panel, no disruptive forced restart.
