#!/usr/bin/env bash
# Auto-toggle the internal laptop panel based on whether the dock's HP monitor is connected.
# Docked (HP present): internal disabled. Externals are NOT touched — nwg-displays/monitors.conf governs them.
# Undocked: internal on, using its monitors.conf line, falling back to FALLBACK_ON if it's `disable`.
#
# Design note: monitors.conf should keep eDP-1 in an *enabled* state (not `disable`) so that an undocked
# boot comes up correctly even if this watcher fails to start or runs late. This script flips eDP-1 OFF
# at runtime when the dock is detected. Save in nwg-displays *while undocked* to persist your laptop
# scale/mode; if you save while docked, nwg-displays will write `disable` for the laptop, and you'll need
# to re-save undocked to recover a robust state.

set -u

INTERNAL='desc:LG Display 0x07C5'
EXTERNAL_TAG='Hewlett Packard HP Pavilion32'
# Always force this position for the internal panel — nwg-displays' tile snapping
# can't reliably place a high-DPI laptop tile relative to lower-DPI external monitors,
# so we override whatever it writes.
INTERNAL_POSITION='1000x1440'
INTERNAL_SCALE='1.0'
# Internal panel extras applied whenever it's enabled. nwg-displays doesn't write these.
INTERNAL_EXTRAS='bitdepth,10'
FALLBACK_ON="preferred,${INTERNAL_POSITION},${INTERNAL_SCALE},${INTERNAL_EXTRAS}"
MONITORS_CONF="${HOME}/.config/hypr/monitors.conf"
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/dock-monitor-toggle.log"

mkdir -p "$(dirname "$LOG")"
log() { printf '%s [%d] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >>"$LOG"; }
log "start (HYPR=${HYPRLAND_INSTANCE_SIGNATURE:-unset})"

internal_on_config() {
    local line rest
    line=$(grep -F "monitor=${INTERNAL}," "$MONITORS_CONF" 2>/dev/null | tail -n1)
    if [[ -z "$line" ]]; then
        printf '%s' "$FALLBACK_ON"
        return
    fi
    rest=${line#monitor=${INTERNAL},}
    if [[ "$rest" == "disable" || -z "$rest" ]]; then
        printf '%s' "$FALLBACK_ON"
        return
    fi
    # Hyprland monitor syntax is MODE,POSITION,SCALE[,extras...].
    # Honor the mode nwg-displays wrote, but always override position and scale
    # so nwg's broken tile snapping for the laptop panel can't take effect.
    local -a parts
    IFS=',' read -ra parts <<<"$rest"
    if (( ${#parts[@]} >= 3 )); then
        parts[1]="$INTERNAL_POSITION"
        parts[2]="$INTERNAL_SCALE"
        rest=$(IFS=','; echo "${parts[*]}")
    fi
    [[ "$rest" != *"bitdepth"* ]] && rest="${rest},bitdepth,10"
    printf '%s' "$rest"
}

docked() {
    hyprctl monitors -j 2>/dev/null \
        | jq -e --arg tag "$EXTERNAL_TAG" 'any(.[]; .description | contains($tag))' >/dev/null
}

apply() {
    local cfg result
    if docked; then
        cfg="${INTERNAL},disable"
    else
        cfg="${INTERNAL},$(internal_on_config)"
    fi
    result=$(hyprctl keyword monitor "$cfg" 2>&1)
    log "apply: docked=$(docked && echo y || echo n)  cfg=${cfg}  result=${result}"
}

# Kill hyprlock before monitor topology changes so it doesn't segfault on a
# vanishing EGL context, then immediately re-lock after things settle.
apply_with_lock_guard() {
    local was_locked=0
    if pgrep -x hyprlock >/dev/null 2>&1; then
        was_locked=1
        pkill -x hyprlock 2>/dev/null || true
        log "lock-guard: stopped hyprlock before monitor change"
    fi
    apply
    if [ "$was_locked" = "1" ]; then
        sleep 0.5
        hyprlock &
        log "lock-guard: restarted hyprlock after monitor change"
    fi
}

# Tiny settle delay so Hyprland's initial monitor parse completes before we override.
sleep 0.5
apply

SOCKET="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"
exec socat -U - "UNIX-CONNECT:${SOCKET}" | while IFS= read -r ev; do
    case "$ev" in
        monitoradded\>\>*|monitoraddedv2\>\>*|monitorremoved\>\>*|monitorremovedv2\>\>*)
            log "event: $ev"
            apply_with_lock_guard
            ;;
        configreloaded\>\>*)
            log "event: $ev"
            apply
            ;;
    esac
done
