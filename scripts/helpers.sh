#!/usr/bin/env bash
# Shared helpers for tmux-pi-session-manager.

# get_tmux_option <option-name> <default>
# Echoes the global tmux option value, or the default when unset/empty.
get_tmux_option() {
  local value
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$2"
  fi
}

# session_hash <string>
# Short, stable, portable 8-char hash for deriving a session name from a path.
# Prefers md5sum (Linux), falls back to md5 (macOS) then shasum. The trailing
# newline matches the conventional `echo "$path" | md5sum` scheme, so it stays
# compatible with sessions created that way.
session_hash() {
  local out
  if command -v md5sum >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5sum)"
  elif command -v md5 >/dev/null 2>&1; then
    out="$(printf '%s\n' "$1" | md5 -q)"
  else
    out="$(printf '%s\n' "$1" | shasum)"
  fi
  out="${out%% *}"
  printf '%s' "${out:0:8}"
}

# normalize_path <path>
# Prints the absolute, symlink-resolved path of an existing directory.
# Falls back to the input unchanged if the directory cannot be entered.
normalize_path() {
  (cd "$1" >/dev/null 2>&1 && pwd -P) || printf '%s' "$1"
}

# file_mtime <path>
# Epoch seconds of a file's last modification. GNU stat (Linux) is tried first,
# then BSD (macOS); each rejects the other's flag, so the fallback is unambiguous.
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

read_signal_records() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '[input_filename, .session // "", .pane_id // "", .cwd // "", .workspace // .cwd // "", .origin // "", .created_at // "", .pid // "", .status // "", .status_at // 0, .orch.desired_state // "active", .orch.task // ""] | join("\u001f")' "$@" 2>/dev/null
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$@" <<'PY'
import json
import sys

def field(value):
    if value is None:
        return ""
    return str(value).replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")

for path in sys.argv[1:]:
    try:
        with open(path) as source:
            data = json.load(source)
    except (OSError, ValueError):
        continue
    orch = data.get("orch") or {}
    values = [path, data.get("session"), data.get("pane_id"), data.get("cwd"),
              data.get("workspace") or data.get("cwd"), data.get("origin"),
              data.get("created_at"), data.get("pid"), data.get("status"),
              data.get("status_at") or 0, orch.get("desired_state") or "active",
              orch.get("task")]
    print("\x1f".join(field(value) for value in values))
PY
  fi
}

load_tmux_panes() {
  local session pane_id pane_pid window_index pane_index key
  # shellcheck disable=SC2034
  PANE_PID=()
  # shellcheck disable=SC2034
  PANE_SESSION=()
  # shellcheck disable=SC2034
  PANE_LOCATION=()

  while IFS=$'\t' read -r session pane_id pane_pid window_index pane_index; do
    [ -n "$pane_id" ] || continue
    key="${pane_id#%}"
    # shellcheck disable=SC2034
    PANE_PID[key]="$pane_pid"
    # shellcheck disable=SC2034
    PANE_SESSION[key]="$session"
    # shellcheck disable=SC2034
    PANE_LOCATION[key]="${session}:${window_index}.${pane_index}"
  done < <(tmux list-panes -a -F $'#{session_name}\t#{pane_id}\t#{pane_pid}\t#{window_index}\t#{pane_index}' 2>/dev/null)
}

load_process_snapshot() {
  local pid ppid state comm
  PROCESS_STATE=()
  PROCESS_COMM=()
  PROCESS_CHILDREN=()

  while read -r pid ppid state comm; do
    [ -n "$pid" ] || continue
    PROCESS_STATE[pid]="$state"
    PROCESS_COMM[pid]="$comm"
    PROCESS_CHILDREN[ppid]="${PROCESS_CHILDREN[ppid]:-} $pid"
  done < <(ps -eo pid=,ppid=,state=,comm= 2>/dev/null)
}

inspect_pane_processes() {
  local pane_pid="$1" child grandchild candidate
  PI_PID=""
  PI_STATE=""
  PI_SUBAGENTS=0

  if [ "${PROCESS_COMM[$pane_pid]:-}" = "pi" ]; then
    PI_PID="$pane_pid"
  else
    for child in ${PROCESS_CHILDREN[$pane_pid]:-}; do
      if [ "${PROCESS_COMM[$child]:-}" = "pi" ]; then
        PI_PID="$child"
        break
      fi
    done
  fi

  if [ -z "$PI_PID" ]; then
    for child in ${PROCESS_CHILDREN[$pane_pid]:-}; do
      for grandchild in ${PROCESS_CHILDREN[$child]:-}; do
        if [ "${PROCESS_COMM[$grandchild]:-}" = "pi" ]; then
          PI_PID="$grandchild"
          break 2
        fi
      done
    done
  fi

  [ -n "$PI_PID" ] || return 1
  # shellcheck disable=SC2034
  PI_STATE="${PROCESS_STATE[PI_PID]:-}"
  for child in ${PROCESS_CHILDREN[$PI_PID]:-}; do
    candidate="$child"
    if [ "${PROCESS_COMM[$candidate]:-}" = "pi" ]; then
      PI_SUBAGENTS=$((PI_SUBAGENTS + 1))
      continue
    fi
    for grandchild in ${PROCESS_CHILDREN[$candidate]:-}; do
      if [ "${PROCESS_COMM[$grandchild]:-}" = "pi" ]; then
        PI_SUBAGENTS=$((PI_SUBAGENTS + 1))
      fi
    done
  done
  return 0
}
