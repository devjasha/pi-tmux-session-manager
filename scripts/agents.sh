#!/usr/bin/env bash
# Emit one picker row per PI session based on signal files.
#
# Output format (tab-separated):
# rank \t pane_id \t pid \t kind \t workspace \t icon \t age \t loc \t path
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

signal_dir="$(get_tmux_option @pi_signal_dir "$HOME/.tmux-pi-session-manager/signals")"
workspace_filter=""
if [ "${1:-}" = "--workspace" ] && [ -n "${2:-}" ]; then
  workspace_filter="$(normalize_path "$2" 2>/dev/null || printf '%s' "$2")"
  shift 2
fi

[ -d "$signal_dir" ] || exit 0
files=("$signal_dir"/*.signal)
[ -f "${files[0]}" ] || exit 0

git_info() {
  local cwd="$1" i data
  GIT_BRANCH=""
  GIT_WORKTREE=""
  for ((i = 0; i < ${#GIT_CWD[@]}; i++)); do
    if [ "${GIT_CWD[$i]}" = "$cwd" ]; then
      GIT_BRANCH="${GIT_BRANCH_CACHE[$i]}"
      GIT_WORKTREE="${GIT_WORKTREE_CACHE[$i]}"
      return
    fi
  done

  if command -v git >/dev/null 2>&1; then
    data="$(git -C "$cwd" rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "$data" = *$'\n'* ]]; then
      GIT_WORKTREE="${data%%$'\n'*}"
      GIT_BRANCH="${data#*$'\n'}"
      if [ "$GIT_BRANCH" = "HEAD" ]; then
        GIT_BRANCH="$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null || true)"
        [ -n "$GIT_BRANCH" ] && GIT_BRANCH="$GIT_BRANCH (detached)"
      fi
    fi
  fi
  i=${#GIT_CWD[@]}
  GIT_CWD[i]="$cwd"
  GIT_BRANCH_CACHE[i]="$GIT_BRANCH"
  GIT_WORKTREE_CACHE[i]="$GIT_WORKTREE"
}

load_tmux_panes
load_process_snapshot
now=$(date +%s)
GIT_CWD=()
GIT_BRANCH_CACHE=()
GIT_WORKTREE_CACHE=()
ROW_RANK=()
ROW_PANE=()
ROW_PID=()
ROW_WORKSPACE=()
ROW_ICON=()
ROW_AGE=()
ROW_LOC=()
ROW_PATH=()
ROW_WORKTREE=()
ROW_SESSION=()

while IFS=$'\x1f' read -r signal session pane_id cwd workspace _origin created_at cached_pid cached_status cached_status_at; do
  [ -n "$session" ] || continue
  [ -n "$pane_id" ] || continue
  [ -n "$cwd" ] || continue
  [ -n "$created_at" ] || continue
  [ -n "$workspace_filter" ] && [ "$workspace" != "$workspace_filter" ] && continue

  pane_key="${pane_id#%}"
  if [ "${PANE_SESSION[$pane_key]:-}" != "$session" ]; then
    # Stale signal; skip for display but do not delete here. Cleanup happens
    # at the real session-closed boundary via cleanup-session.sh.
    continue
  fi
  pane_pid="${PANE_PID[$pane_key]}"

  use_cache=""
  if [ -n "$cached_status" ] && [ "$((now - cached_status_at))" -lt 60 ] 2>/dev/null; then
    if [ -n "$cached_pid" ] && [ -n "${PROCESS_COMM[$cached_pid]:-}" ]; then
      use_cache=1
    elif [ -z "$cached_pid" ]; then
      use_cache=1
    fi
  fi

  inspect_pane_processes "$pane_pid" || true
  if [ -n "$use_cache" ]; then
    status="$cached_status"
    pid="${cached_pid:-$pane_pid}"
  elif [ -z "$PI_PID" ]; then
    status="idle"
    pid="$pane_pid"
  else
    pid="$PI_PID"
    if [[ "$PI_STATE" = R* ]]; then
      status="working"
    else
      status="waiting"
    fi
  fi

  sub_badge=""
  if [ "$pid" != "$pane_pid" ] && [ "$PI_SUBAGENTS" -gt 0 ]; then
    sub_badge=$'  \033[2;90m+'"$PI_SUBAGENTS"$'\033[0m'
  fi

  case "$status" in
    waiting) icon=$'\033[33m●\033[0m waiting'; rank=0 ;;
    idle) icon=$'\033[32m●\033[0m idle'; rank=1 ;;
    working) icon=$'\033[31m●\033[0m working'; rank=3 ;;
    *) icon=$'\033[90m●\033[0m   ?'; rank=2 ;;
  esac
  icon="${icon}${sub_badge}"

  if [ "$created_at" -gt 0 ] 2>/dev/null; then
    age="$(((now - created_at) / 60))m"
  else
    age="-"
  fi
  loc="${PANE_LOCATION[$pane_key]:-${session}:unknown}"
  if [ "${cwd#"$HOME"}" != "$cwd" ]; then
    path="~${cwd#"$HOME"}"
  else
    path="$cwd"
  fi

  git_info "$cwd"
  [ -n "$GIT_BRANCH" ] && path="$path [$GIT_BRANCH]"
  i=${#ROW_RANK[@]}
  ROW_RANK[i]="$rank"
  ROW_PANE[i]="$pane_id"
  ROW_PID[i]="$pid"
  ROW_WORKSPACE[i]="$workspace"
  ROW_ICON[i]="$icon"
  ROW_AGE[i]="$age"
  ROW_LOC[i]="$loc"
  ROW_PATH[i]="$path"
  ROW_WORKTREE[i]="$GIT_WORKTREE"
  ROW_SESSION[i]="$session"
done < <(read_signal_records "${files[@]}")

for ((i = 0; i < ${#ROW_RANK[@]}; i++)); do
  collision=""
  if [ -n "${ROW_WORKTREE[$i]}" ]; then
    for ((j = 0; j < ${#ROW_RANK[@]}; j++)); do
      [ "$i" -ne "$j" ] && [ "${ROW_WORKTREE[$i]}" = "${ROW_WORKTREE[$j]}" ] && collision="⚠️  " && break
    done
  fi
  printf '%s\t%s\t%s\tdedicated\t%s\t%s%s\t%5s\t%s\t%s\t%s\t%s\n' \
    "${ROW_RANK[$i]}" "${ROW_PANE[$i]}" "${ROW_PID[$i]}" "${ROW_WORKSPACE[$i]}" \
    "$collision" "${ROW_ICON[$i]}" "${ROW_AGE[$i]}" "${ROW_LOC[$i]}" \
    "${ROW_PATH[$i]}" "${ROW_WORKTREE[$i]}" "${ROW_SESSION[$i]}"
done | sort -t$'\t' -k1,1n -k6,6n
