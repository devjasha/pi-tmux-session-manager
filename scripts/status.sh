#!/usr/bin/env bash
# Status-bar indicator for PI sessions that need attention.
# Outputs a compact tmux-formatted string meant for status-right.
#
# Prefers cached status from the signal file when fresh (< 60 s);
# otherwise falls back to live process inspection.
# Paused sessions are excluded because they do not need attention.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

signal_dir="$(get_tmux_option @pi_signal_dir "$HOME/.tmux-pi-session-manager/signals")"
[ -d "$signal_dir" ] || exit 0

waiting_color="$(get_tmux_option @pi_status_waiting_color 'yellow')"
idle_color="$(get_tmux_option @pi_status_idle_color 'green')"
waiting_format="$(get_tmux_option @pi_status_waiting_format '#[fg={color}]⏸ {count}#[default]')"
idle_format="$(get_tmux_option @pi_status_idle_format '#[fg={color}]✔ {count}#[default]')"
sep="$(get_tmux_option @pi_status_separator ' | ')"

waiting=0
idle=0
now=$(date +%s)
files=("$signal_dir"/*.signal)
[ -f "${files[0]}" ] || exit 0
load_tmux_panes
processes_loaded=""

while IFS=$'\x1f' read -r signal session pane_id _cwd _workspace _origin _created_at _pid cached_status cached_status_at orch_state _task; do
  [ -z "$session" ] && continue
  [ -z "$pane_id" ] && continue
  [ "$orch_state" = "paused" ] && continue
  pane_key="${pane_id#%}"
  if [ "${PANE_SESSION[$pane_key]:-}" != "$session" ]; then
    rm -f "$signal" 2>/dev/null
    continue
  fi

  status=""
  if [ -n "$cached_status" ] && \
     [ "$((now - cached_status_at))" -lt 60 ] 2>/dev/null; then
    status="$cached_status"
  fi

  if [ -z "$status" ]; then
    if [ -z "$processes_loaded" ]; then
      load_process_snapshot
      processes_loaded=1
    fi
    if ! inspect_pane_processes "${PANE_PID[$pane_key]}"; then
      status="idle"
    elif [[ "$PI_STATE" = R* ]]; then
      status="working"
    else
      status="waiting"
    fi
  fi

  case "$status" in
    waiting) waiting=$((waiting + 1)) ;;
    idle)    idle=$((idle + 1)) ;;
  esac
done < <(read_signal_records "${files[@]}")

out=""
if [ "$waiting" -gt 0 ]; then
  fmt="$waiting_format"
  fmt="${fmt//\{color\}/$waiting_color}"
  fmt="${fmt//\{count\}/$waiting}"
  out="$fmt"
fi

if [ "$idle" -gt 0 ]; then
  fmt="$idle_format"
  fmt="${fmt//\{color\}/$idle_color}"
  fmt="${fmt//\{count\}/$idle}"
  if [ -n "$out" ]; then
    out="$out$sep$fmt"
  else
    out="$fmt"
  fi
fi

[ -n "$out" ] && printf '%s' "$out"
