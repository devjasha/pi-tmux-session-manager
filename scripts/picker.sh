#!/usr/bin/env bash
# Interactive picker for running PI agents.
#
#   picker.sh           fzf picker; on enter, jumps to the chosen agent.
#   picker.sh --list    print the rows and refresh the cache (used by fzf's
#                       async initial load and by the ctrl-x reload).
#
# Rows come from agents.sh, which pairs each running PI with the tmux pane it
# occupies. Two kinds of row jump differently:
#   dedicated  a PI in a `pi-*` session this plugin launched — resumed in
#              the popup, over the window it was launched from.
#   loose      a PI running in any other pane — focused in place.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

workspace="${1:-}"
workspace="$(normalize_path "$workspace" 2>/dev/null || printf '%s' "$workspace")"
cache="${TMPDIR:-/tmp}/tmux-pi-agents-v2-$(id -u).cache"

if [ "${1:-}" = '--list' ]; then
  # When called internally, shift workspace args so agents.sh gets the filter.
  # $0 is the script path; $1 is --list; remaining args are workspace flags.
  shift 1
  tmp="$cache.$$"
  "$DIR/agents.sh" "$@" >"$tmp" 2>/dev/null
  mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
  cat "$cache" 2>/dev/null
  exit 0
fi

for tool in fzf jq pi; do
  command -v "$tool" >/dev/null 2>&1 || {
    tmux display-message "tmux-pi-session-manager: $tool is required for the picker"
    exit 0
  }
done

self="$DIR/picker.sh"
export PI_PICKER="$self"

# Arbitrary user fzf options (e.g. custom --bind or --preview-window)
extra_opts=()
fzf_options="$(get_tmux_option @pi_fzf_options '')"
[ -n "$fzf_options" ] && eval "extra_opts=($fzf_options)"

reload_list="$self --list"
[ -n "$workspace" ] && reload_list="$reload_list --workspace '$workspace'"

# Load the session list asynchronously
list_cmd=("$self" --list ${workspace:+--workspace "$workspace"})
sync_opts=()
now=$(date +%s)
mtime=$(file_mtime "$cache")
if [ -z "$workspace" ] && [ -s "$cache" ] && [ -n "$mtime" ] && [ $((now - mtime)) -lt 3600 ]; then
  list_cmd=(cat "$cache")
  sync_opts=("--bind" "load:unbind(load)+reload-sync($reload_list)")
fi
fzf --track --version >/dev/null 2>&1 && sync_opts+=(--track)

workspace_display="$workspace"
home="$HOME"
if [ -n "$workspace_display" ] && [ "${workspace_display#"$home"}" != "$workspace_display" ]; then
  workspace_display="~${workspace_display#"$HOME"}"
fi
header="PI agents · enter: jump · ctrl-x: kill"
[ -n "$workspace_display" ] && header="${header}   📁 ${workspace_display}"

# ctrl-x kills the PI process itself: a dedicated session dies with its last
# window, while a loose pane keeps the shell that hosted it. The reload waits a
# beat so the process tree has settled.
list_out=$("${list_cmd[@]}" 2>/dev/null)
collision_count=$(printf '%s\n' "$list_out" | awk -F '\t' '$10 != "" {c[$10]++} END {n=0; for (w in c) if (c[w]>1) n+=c[w]; print n}')
if [ "$collision_count" -gt 0 ]; then
  header="${header}   ⚠️ ${collision_count} collision(s)"
fi

sel=$(if [ -n "$list_out" ]; then printf '%s\n' "$list_out"; else :; fi | fzf --ansi --delimiter='\t' --with-nth=6,7,8,9 \
  --reverse --cycle --header="$header" \
  --preview='tmux capture-pane -ept {2}' --preview-window='right,50%,follow' \
  --bind="ctrl-x:execute-silent(kill {3})+reload(sleep 0.3; $reload_list)" \
  ${sync_opts[@]+"${sync_opts[@]}"} \
  ${extra_opts[@]+"${extra_opts[@]}"})

[ -z "$sel" ] && exit 0
pane=$(printf '%s' "$sel" | cut -f2)
kind=$(printf '%s' "$sel" | cut -f4)

parent=$(tmux show-options -gqv @pi_parent 2>/dev/null)
session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)

if [ "$kind" = loose ]; then
  # Focus the pane in place on the outer client. This popup closes on its own
  # when the script exits.
  if [ -n "$parent" ]; then
    tmux switch-client -c "$parent" -t "$session" 2>/dev/null
  else
    tmux switch-client -t "$session" 2>/dev/null
  fi
  tmux select-window -t "$pane" 2>/dev/null
  tmux select-pane -t "$pane" 2>/dev/null
  exit 0
fi

# Move the parent client to the window the session was launched from (best-effort),
# focus the chosen PI's own window inside that session, then resume it in THIS
# popup over the top. Falls back to resuming over the current window when
# origin/parent are unknown.
origin=$(tmux show-options -qv -t "$session" @pi_origin 2>/dev/null)
[ -n "$origin" ] && [ -n "$parent" ] &&
  tmux switch-client -c "$parent" -t "$origin" 2>/dev/null

tmux select-window -t "$pane" 2>/dev/null
tmux select-pane -t "$pane" 2>/dev/null
tmux attach-session -t "$session"
