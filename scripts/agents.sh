#!/usr/bin/env bash
# Emit one picker row per PI session based on signal files.
#
# Status is inferred live from the process running in the pane:
#   working  pi is actively running (R state)
#   waiting  pi is sleeping/blocked (S/D state) — likely waiting for input
#   idle     pi is no longer running in the pane
#
# Output format (tab-separated):
# rank \t pane_id \t pid \t kind \t icon \t age \t loc \t path
#
# rank/pane_id/pid/kind are hidden from the display via fzf's --with-nth.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

signal_dir="$(get_tmux_option @pi_signal_dir $HOME/.tmux-pi-session-manager/signals)"

[ -d "$signal_dir" ] || exit 0

# Find the pi process in a pane and return its state letter (R, S, etc.)
# First arg is the pane PID from tmux (shell or pi itself).
pi_state_from_pane_pid() {
  local pane_pid="$1"
  local comm pid state

  # Direct: pane PID is pi itself
  comm=$(ps -o comm= -p "$pane_pid" 2>/dev/null | tr -d ' ')
  if [ "$comm" = "pi" ]; then
    ps -o state= -p "$pane_pid" 2>/dev/null | tr -d ' '
    return 0
  fi

  # Depth 1: direct children of the shell
  for pid in $(pgrep -P "$pane_pid" 2>/dev/null); do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ "$comm" = "pi" ]; then
      ps -o state= -p "$pid" 2>/dev/null | tr -d ' '
      return 0
    fi
  done

  # Depth 2: wrapper → pi
  for pid in $(pgrep -P "$pane_pid" 2>/dev/null); do
    for child in $(pgrep -P "$pid" 2>/dev/null); do
      comm=$(ps -o comm= -p "$child" 2>/dev/null | tr -d ' ')
      if [ "$comm" = "pi" ]; then
        ps -o state= -p "$child" 2>/dev/null | tr -d ' '
        return 0
      fi
    done
  done

  return 1
}

for signal in "$signal_dir"/*.signal; do
  [ -f "$signal" ] || continue

  if command -v jq >/dev/null 2>&1; then
    session=$(jq -r '.session' "$signal" 2>/dev/null)
    pane_id=$(jq -r '.pane_id' "$signal" 2>/dev/null)
    cwd=$(jq -r '.cwd' "$signal" 2>/dev/null)
    origin=$(jq -r '.origin' "$signal" 2>/dev/null)
    created_at=$(jq -r '.created_at' "$signal" 2>/dev/null)
  else
    session=$(sed -n 's/.*"session": "\([^"]*\)".*/\1/p' "$signal")
    pane_id=$(sed -n 's/.*"pane_id": "\([^"]*\)".*/\1/p' "$signal")
    cwd=$(sed -n 's/.*"cwd": "\([^"]*\)".*/\1/p' "$signal")
    origin=$(sed -n 's/.*"origin": "\([^"]*\)".*/\1/p' "$signal")
    created_at=$(sed -n 's/.*"created_at": \([0-9]*\).*/\1/p' "$signal")
  fi

  [ -z "$session" ] && continue
  [ -z "$pane_id" ] && continue
  [ -z "$cwd" ] && continue
  [ -z "$created_at" ] && continue

  # Skip if the tmux session is gone (stale signal file)
  if ! tmux has-session -t "$session" 2>/dev/null; then
    rm -f "$signal"
    continue
  fi

  # PID from tmux is the shell that owns the pane; resolve to pi if nested
  pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid} #{pane_id}' 2>/dev/null |
             awk -v pid="$pane_id" '$2 == pid { print $1; exit }')
  [ -z "$pane_pid" ] && continue

  state=$(pi_state_from_pane_pid "$pane_pid")
  if [ -n "$state" ]; then
    case "$state" in
      R*) status="working" ;;
      *)  status="waiting" ;;
    esac
  else
    status="idle"
  fi

  # Resolve the actual pi PID for the kill binding (fall back to pane PID)
  pid="$pane_pid"
  for p in $(pgrep -P "$pane_pid" 2>/dev/null); do
    if [ "$(ps -o comm= -p "$p" 2>/dev/null | tr -d ' ')" = "pi" ]; then
      pid="$p"
      break
    fi
  done
  # Try one level deeper if still not found
  if [ "$pid" = "$pane_pid" ]; then
    for p in $(pgrep -P "$pane_pid" 2>/dev/null); do
      for c in $(pgrep -P "$p" 2>/dev/null); do
        if [ "$(ps -o comm= -p "$c" 2>/dev/null | tr -d ' ')" = "pi" ]; then
          pid="$c"
          break 2
        fi
      done
    done
  fi

  kind="dedicated"

  case "$status" in
    waiting)
      icon=$'\033[33m●\033[0m waiting'
      rank=0
      ;;
    idle)
      icon=$'\033[32m●\033[0m idle'
      rank=1
      ;;
    working)
      icon=$'\033[31m●\033[0m working'
      rank=3
      ;;
    *)
      icon=$'\033[90m●\033[0m   ?'
      rank=2
      ;;
  esac

  now=$(date +%s)
  if [ "$created_at" -gt 0 ] 2>/dev/null; then
    age_minutes=$(((now - created_at) / 60))
    age="${age_minutes}m"
  else
    age="-"
  fi

  loc=$(tmux display-message -p -t "$pane_id" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
  if [ -z "$loc" ]; then
    window_index=$(tmux display-message -p -t "$pane_id" '#{window_index}' 2>/dev/null)
    pane_index=$(tmux display-message -p -t "$pane_id" '#{pane_index}' 2>/dev/null)
    if [ -n "$window_index" ] && [ -n "$pane_index" ]; then
      loc="${session}:${window_index}.${pane_index}"
    else
      loc="${session}:unknown"
    fi
  fi

  home="$HOME"
  if [ "${cwd#"$home"}" != "$cwd" ]; then
    path="~${cwd#"$home"}"
  else
    path="$cwd"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%5s\t%s\t%s\n' \
    "$rank" "$pane_id" "$pid" "$kind" "$icon" "$age" "$loc" "$path"
done | sort -t$'\t' -k1,1n -k6,6n
