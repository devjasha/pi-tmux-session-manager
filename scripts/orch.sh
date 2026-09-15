#!/usr/bin/env bash
# orch.sh — Orchestrator commands for PI session lifecycle.
#
# Usage: orch.sh <command> [args...]
#
# Commands:
#   health [--force]              Update stale status in all signal files.
#   pause <session>               SIGSTOP the pi process.
#   resume <session>              SIGCONT the pi process.
#   toggle <session>              Toggle pause / resume.
#   kill <session>                Kill pi, escalating to SIGKILL after a short wait.
#   queue <session> <line...>     Queue input for a session.
#   send <session>                Send queued input via tmux send-keys.
#   set-task <session> <task>     Set a task description.
#   status <session>              Show detailed status.
#   cleanup                       Remove stale signal files.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

signal_dir="$(get_tmux_option @pi_signal_dir "$HOME/.tmux-pi-session-manager/signals")"
queue_dir="$HOME/.tmux-pi-session-manager/queue"
mkdir -p "$signal_dir" "$queue_dir"

# ---------------------------------------------------------------------------
# JSON helpers — jq preferred, python3 fallback
# ---------------------------------------------------------------------------

jq_or_py() {
  local file="$1"
  local jq_expr="$2"
  local py_expr="$3"

  if command -v jq >/dev/null 2>&1; then
    jq -r "$jq_expr" "$file" 2>/dev/null
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; d=json.load(open('$file')); $py_expr" 2>/dev/null
    return
  fi

  # Last resort: basic sed extraction
  # This only works for flat top-level string fields
  local key
  key="$(printf '%s' "$jq_expr" | sed 's/^\.//')"
  sed -n "s/.*\"$key\": *\"\([^\"]*\)\".*/\1/p" "$file" 2>/dev/null | head -n1
}

update_json() {
  local file="$1"
  local jq_expr="$2"
  local py_expr="$3"
  local tmp
  tmp="$(mktemp)"

  if command -v jq >/dev/null 2>&1; then
    jq "$jq_expr" "$file" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json, sys
try:
    with open('$file') as f: d = json.load(f)
    $py_expr
    with open('$tmp', 'w') as f: json.dump(d, f, indent=2)
    import os; os.rename('$tmp', '$file')
except Exception as e: sys.exit(1)
" 2>/dev/null && return
  fi

  rm -f "$tmp"
  return 1
}

# ---------------------------------------------------------------------------
# Signal-file helpers
# ---------------------------------------------------------------------------

ensure_orch_field() {
  local file="$1"
  # If .orch is missing, add it with defaults.
  update_json "$file" \
    '.orch //= {"desired_state":"active","paused_at":null,"task":"","queue_length":0}' \
    'd.setdefault("orch", {"desired_state":"active","paused_at":None,"task":"","queue_length":0})'
}

read_pane_id() {
  local file="$1"
  jq_or_py "$file" '.pane_id' 'print(d.get("pane_id",""))'
}

read_session() {
  local file="$1"
  jq_or_py "$file" '.session' 'print(d.get("session",""))'
}

read_orch_state() {
  local file="$1"
  jq_or_py "$file" '.orch.desired_state // "active"' 'print(d.get("orch",{}).get("desired_state","active"))'
}

read_pid() {
  local file="$1"
  jq_or_py "$file" '.pid // empty' 'print(d.get("pid",""))'
}

set_orch_state() {
  local file="$1" state="$2" ts="$3"
  if [ "$state" = "active" ]; then
    update_json "$file" \
      '.orch.desired_state = "active" | .orch.paused_at = null' \
      'd["orch"]["desired_state"]="active"; d["orch"]["paused_at"]=None'
  else
    update_json "$file" \
      ".orch.desired_state = \"$state\" | .orch.paused_at = $ts" \
      "d['orch']['desired_state']='$state'; d['orch']['paused_at']=$ts"
  fi
}

set_task() {
  local file="$1" task="$2"
  update_json "$file" \
    ".orch.task = \"$task\"" \
    "d['orch']['task']='$task'"
}

set_pid_status() {
  local file="$1" pid="$2" status="$3" ts="$4"
  update_json "$file" \
    ".orch //= {\"desired_state\":\"active\",\"paused_at\":null,\"task\":\"\",\"queue_length\":0} | .pid = $pid | .status = \"$status\" | .status_at = $ts" \
    "d.setdefault('orch', {'desired_state':'active','paused_at':None,'task':'','queue_length':0}); d['pid']=$pid; d['status']='$status'; d['status_at']=$ts"
}

set_queue_length() {
  local file="$1" n="$2"
  update_json "$file" \
    ".orch.queue_length = $n" \
    "d['orch']['queue_length']=$n"
}

# ---------------------------------------------------------------------------
# Per-session actions
# ---------------------------------------------------------------------------

cmd_health() {
  local force="${1:-}" lock_dir="$signal_dir/.health.lock" lock_pid=""
  local file session pane_id cached_status cached_status_at desired pane_key pane_pid status pi_pid now processes_loaded=""
  local files
  files=("$signal_dir"/*.signal)
  [ -f "${files[0]}" ] || return 0

  if ! mkdir "$lock_dir" 2>/dev/null; then
    [ -f "$lock_dir/pid" ] && read -r lock_pid < "$lock_dir/pid"
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      rm -rf "$lock_dir"
      mkdir "$lock_dir" 2>/dev/null || return 0
    else
      return 0
    fi
  fi
  printf '%s\n' "$$" > "$lock_dir/pid"
  health_lock_dir="$lock_dir"
  trap 'rm -rf "$health_lock_dir"' EXIT

  load_tmux_panes
  now=$(date +%s)
  while IFS=$'\x1f' read -r file session pane_id _cwd _workspace _origin _created_at _cached_pid cached_status cached_status_at desired _task; do
    [ -n "$session" ] || continue
    pane_key="${pane_id#%}"
    if [ "${PANE_SESSION[$pane_key]:-}" != "$session" ]; then
      # Stale signal; skip but do not delete here. Cleanup is handled by the
      # session-closed hook via cleanup-session.sh.
      continue
    fi
    if [ "$force" != "--force" ] && [ -n "$cached_status" ] && \
       [ "$((now - cached_status_at))" -lt 60 ] 2>/dev/null; then
      printf '%s\t%s\n' "$session" "$cached_status"
      continue
    fi

    if [ -z "$processes_loaded" ]; then
      load_process_snapshot
      processes_loaded=1
    fi
    pane_pid="${PANE_PID[$pane_key]}"
    inspect_pane_processes "$pane_pid" || true
    pi_pid="$PI_PID"
    if [ -z "$pi_pid" ]; then
      status="idle"
    elif [[ "$PI_STATE" = R* ]]; then
      status="working"
    else
      status="waiting"
    fi
    set_pid_status "$file" "${pi_pid:-null}" "$status" "$now"
    if [ "$desired" = "paused" ] && [ -n "$pi_pid" ]; then
      kill -STOP "$pi_pid" 2>/dev/null
    elif [ "$desired" = "active" ] && [ -n "$pi_pid" ]; then
      kill -CONT "$pi_pid" 2>/dev/null
    fi
    printf '%s\t%s\n' "$session" "$status"
  done < <(read_signal_records "${files[@]}")
}

cmd_pause() {
  local session="$1"
  [ -n "$session" ] || { echo "Usage: orch.sh pause <session>" >&2; exit 1; }
  local file="$signal_dir/$session.signal"
  [ -f "$file" ] || { echo "No signal file for $session" >&2; exit 1; }

  ensure_orch_field "$file"
  local pid
  pid="$(read_pid "$file")"
  [ -n "$pid" ] && [ "$pid" != "null" ] && kill -STOP "$pid" 2>/dev/null
  set_orch_state "$file" "paused" "$(date +%s)"
  printf 'Paused %s\n' "$session"
}

cmd_resume() {
  local session="$1"
  [ -n "$session" ] || { echo "Usage: orch.sh resume <session>" >&2; exit 1; }
  local file="$signal_dir/$session.signal"
  [ -f "$file" ] || { echo "No signal file for $session" >&2; exit 1; }

  ensure_orch_field "$file"
  local pid
  pid="$(read_pid "$file")"
  [ -n "$pid" ] && [ "$pid" != "null" ] && kill -CONT "$pid" 2>/dev/null
  set_orch_state "$file" "active" ""
  printf 'Resumed %s\n' "$session"
}

cmd_toggle() {
  local session="$1"
  [ -n "$session" ] || { echo "Usage: orch.sh toggle <session>" >&2; exit 1; }
  local file="$signal_dir/$session.signal"
  [ -f "$file" ] || { echo "No signal file for $session" >&2; exit 1; }

  ensure_orch_field "$file"
  local state
  state="$(read_orch_state "$file")"
  if [ "$state" = "paused" ]; then
    cmd_resume "$session"
  else
    cmd_pause "$session"
  fi
}

cmd_kill() {
  local session="$1"
  [ -n "$session" ] || { echo "Usage: orch.sh kill <session>" >&2; exit 1; }
  local file="$signal_dir/$session.signal"
  [ -f "$file" ] || { echo "No signal file for $session" >&2; exit 1; }

  local pid
  pid="$(read_pid "$file")"

  if [ -n "$pid" ] && [ "$pid" != "null" ]; then
    kill -TERM "$pid" 2>/dev/null
    sleep 0.5
    kill -0 "$pid" 2>/dev/null && sleep 1 && kill -KILL "$pid" 2>/dev/null
  fi

  # Tear down the tmux session so the picker cleans it up naturally.
  tmux kill-session -t "$session" 2>/dev/null
  rm -f "$file"
  printf 'Killed %s\n' "$session"
}

cmd_queue() {
  local session="$1"
  shift
  [ -n "$session" ] || { echo "Usage: orch.sh queue <session> <line...>" >&2; exit 1; }
  local file="$signal_dir/$session.signal"
  [ -f "$file" ] || { echo "No signal file for $session" >&2; exit 1; }

  local line
  line="$*"
  [ -z "$line" ] && { echo "Nothing to queue." >&2; exit 1; }

  local qfile="$queue_dir/$session"
  printf '%s\n' "$line" >> "$qfile"

  ensure_orch_field "$file"
  local n
  n="$(wc -l < "$qfile" | tr -d ' ')"
  set_queue_length "$file" "$n"
  printf 'Queued (%s total) for %s\n' "$n" "$session"
}

cmd_send() {
  local session="$1"
  [ -n "$session" ] || { echo "Usage: orch.sh send <session>" >&2; exit 1; }
  local file="$signal_dir/$session.signal"
  [ -f "$file" ] || { echo "No signal file for $session" >&2; exit 1; }

  local qfile="$queue_dir/$session"
  [ -f "$qfile" ] || { echo "Queue empty." >&2; exit 0; }

  local pane_id
  pane_id="$(read_pane_id "$file")"
  [ -n "$pane_id" ] || { echo "No pane ID." >&2; exit 1; }

  while IFS= read -r line || [ -n "$line" ]; do
    tmux send-keys -t "$pane_id" -l "$line"
    tmux send-keys -t "$pane_id" C-m
  done < "$qfile"

  rm -f "$qfile"
  set_queue_length "$file" 0
  printf 'Sent queued input to %s\n' "$session"
}

cmd_set_task() {
  local session="$1"
  shift
  [ -n "$session" ] || { echo "Usage: orch.sh set-task <session> <task>" >&2; exit 1; }
  local file="$signal_dir/$session.signal"
  [ -f "$file" ] || { echo "No signal file for $session" >&2; exit 1; }

  local task
  task="$*"
  ensure_orch_field "$file"
  set_task "$file" "$task"
  printf 'Task set for %s\n' "$session"
}

cmd_status() {
  local session="$1"
  [ -n "$session" ] || { echo "Usage: orch.sh status <session>" >&2; exit 1; }
  local file="$signal_dir/$session.signal"
  [ -f "$file" ] || { echo "No signal file for $session" >&2; exit 1; }

  if command -v jq >/dev/null 2>&1; then
    jq . "$file"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$file"
  else
    cat "$file"
  fi
}

cmd_cleanup() {
  local file session
  for file in "$signal_dir"/*.signal; do
    [ -f "$file" ] || continue
    session="$(read_session "$file")"
    if [ -z "$session" ] || ! tmux has-session -t "$session" 2>/dev/null; then
      rm -f "$file"
      rm -f "$queue_dir/$session"
      printf 'Cleaned up %s\n' "${session:-$(basename "$file" .signal)}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

cmd="${1:-}"
shift 2>/dev/null || true

case "$cmd" in
  health)    cmd_health "$@" ;;
  pause)     cmd_pause "$1" ;;
  resume)    cmd_resume "$1" ;;
  toggle)    cmd_toggle "$1" ;;
  kill)      cmd_kill "$1" ;;
  queue)     cmd_queue "$@" ;;
  send)      cmd_send "$1" ;;
  set-task)  cmd_set_task "$@" ;;
  status)    cmd_status "$1" ;;
  cleanup)   cmd_cleanup ;;
  *)
    cat >&2 <<'EOF'
Usage: orch.sh <command> [args...]

Commands:
  health [--force]              Update stale status in all signal files.
  pause <session>               SIGSTOP the pi process.
  resume <session>              SIGCONT the pi process.
  toggle <session>              Toggle pause / resume.
  kill <session>                Kill pi, escalating to SIGKILL.
  queue <session> <line...>     Queue input for a session.
  send <session>                Send queued input via tmux send-keys.
  set-task <session> <task>     Set a task description.
  status <session>              Show detailed status.
  cleanup                       Remove stale signal files.
EOF
    exit 1
    ;;
esac
