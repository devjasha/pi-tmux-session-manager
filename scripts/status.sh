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

# Determine whether a pane's pi process is in the requested state.
# Returns 0 if the pane matches, 1 otherwise.
#   waiting  → pi exists and is NOT in R (running) state
#   idle     → no pi process found in the pane tree
pane_is_state() {
  local pane_pid="$1" want="$2"
  local comm pid state child

  # Direct: pane PID is pi itself
  comm=$(ps -o comm= -p "$pane_pid" 2>/dev/null | tr -d ' ')
  if [ "$comm" = "pi" ]; then
    if [ "$want" = "idle" ]; then
      return 1
    fi
    state=$(ps -o state= -p "$pane_pid" 2>/dev/null | tr -d ' ')
    [ "$state" != "R" ] && return 0 || return 1
  fi

  # Depth 1: direct children of the shell
  for pid in $(pgrep -P "$pane_pid" 2>/dev/null); do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ "$comm" = "pi" ]; then
      if [ "$want" = "idle" ]; then
        return 1
      fi
      state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "$state" != "R" ] && return 0 || return 1
    fi
  done

  # Depth 2: wrapper → pi
  for pid in $(pgrep -P "$pane_pid" 2>/dev/null); do
    for child in $(pgrep -P "$pid" 2>/dev/null); do
      comm=$(ps -o comm= -p "$child" 2>/dev/null | tr -d ' ')
      if [ "$comm" = "pi" ]; then
        if [ "$want" = "idle" ]; then
          return 1
        fi
        state=$(ps -o state= -p "$child" 2>/dev/null | tr -d ' ')
        [ "$state" != "R" ] && return 0 || return 1
      fi
    done
  done

  # No pi process found anywhere
  if [ "$want" = "idle" ]; then
    return 0
  fi
  return 1
}

waiting=0
idle=0
now=$(date +%s)

for signal in "$signal_dir"/*.signal; do
  [ -f "$signal" ] || continue

  if command -v jq >/dev/null 2>&1; then
    session=$(jq -r '.session // empty' "$signal" 2>/dev/null)
    pane_id=$(jq -r '.pane_id // empty' "$signal" 2>/dev/null)
    cached_status=$(jq -r '.status // empty' "$signal" 2>/dev/null)
    cached_status_at=$(jq -r '.status_at // 0' "$signal" 2>/dev/null)
    orch_state=$(jq -r '.orch.desired_state // "active"' "$signal" 2>/dev/null)
  else
    session=$(sed -n 's/.*"session": "\([^"]*\)".*/\1/p' "$signal")
    pane_id=$(sed -n 's/.*"pane_id": "\([^"]*\)".*/\1/p' "$signal")
    cached_status=""
    cached_status_at=0
    orch_state="active"
  fi

  [ -z "$session" ] && continue
  [ -z "$pane_id" ] && continue

  # Skip paused sessions; they do not need attention.
  if [ "$orch_state" = "paused" ]; then
    continue
  fi

  if ! tmux has-session -t "$session" 2>/dev/null; then
    rm -f "$signal" 2>/dev/null
    continue
  fi

  # Prefer cached status when fresh (< 60 s).
  status=""
  if [ -n "$cached_status" ] && [ -n "$cached_status_at" ] && \
     [ "$((now - cached_status_at))" -lt 60 ] 2>/dev/null; then
    status="$cached_status"
  fi

  if [ -z "$status" ]; then
    pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid} #{pane_id}' 2>/dev/null |
               awk -v pid="$pane_id" '$2 == pid { print $1; exit }')
    [ -z "$pane_pid" ] && continue

    if pane_is_state "$pane_pid" "waiting"; then
      status="waiting"
    elif pane_is_state "$pane_pid" "idle"; then
      status="idle"
    else
      status="working"
    fi
  fi

  case "$status" in
    waiting) waiting=$((waiting + 1)) ;;
    idle)    idle=$((idle + 1)) ;;
  esac
done

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
