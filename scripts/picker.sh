#!/usr/bin/env bash
# Interactive picker for running PI agents.
#
#   picker.sh           fzf picker; on enter jumps to the chosen agent in a
#                       popup, or press the pane key to open it in a new pane.
#   picker.sh --list    print the rows and refresh the cache (used by fzf's
#                       async initial load).
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

# Arbitrary user fzf options (e.g. custom --bind or --preview-window)
extra_opts=()
fzf_options="$(get_tmux_option @pi_fzf_options '')"
[ -n "$fzf_options" ] && eval "extra_opts=($fzf_options)"

pane_key="$(get_tmux_option @pi_picker_pane_key 'alt-o')"

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
header="PI agents · enter: jump"
[ -n "$pane_key" ] && header="${header} · ${pane_key}: open in pane"
header="${header} · ctrl-c: close"

list_out=$("${list_cmd[@]}" 2>/dev/null)
collision_count=$(printf '%s\n' "$list_out" | awk -F '\t' '$10 != "" {c[$10]++} END {n=0; for (w in c) if (c[w]>1) n+=c[w]; print n}')
if [ "$collision_count" -gt 0 ]; then
  header="${header}   ⚠️ ${collision_count} collision(s)"
fi

# Build footer with wrapped workspace text (bottom-left placement via --footer)
footer=""
if [ -n "$workspace_display" ]; then
  cols=$(tput cols 2>/dev/null || echo 80)
  max_width=$((cols - 4))
  footer=$(printf '📁 %s' "$workspace_display" | fold -s -w "$max_width")
fi

fzf_base_opts=(
  --ansi --delimiter='\t' --with-nth=6,7,8,9
  --reverse --cycle
  --header="$header"
  --wrap=word
  --preview='tmux capture-pane -ept {2}'
  --preview-window='right,50%,follow'
)
[ -n "$footer" ] && fzf_base_opts+=(--footer="$footer")

expect_opts=()
[ -n "$pane_key" ] && expect_opts=("--expect=$pane_key")

sel=$(if [ -n "$list_out" ]; then printf '%s\n' "$list_out"; else :; fi | fzf "${fzf_base_opts[@]}" \
  ${expect_opts[@]+"${expect_opts[@]}"} \
  ${sync_opts[@]+"${sync_opts[@]}"} \
  ${extra_opts[@]+"${extra_opts[@]}"})

[ -z "$sel" ] && exit 0
key=$(printf '%s\n' "$sel" | head -n1)

if [ "$key" = "$pane_key" ]; then
  pane_sel=$(printf '%s\n' "$sel" | tail -n +2)
  [ -z "$pane_sel" ] && exit 0
  pane=$(printf '%s' "$pane_sel" | cut -f2)
  session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
  parent=$(tmux show-options -gqv @pi_parent 2>/dev/null)

  # Open the selected session in a new window pane on the parent client.
  if [ -n "$parent" ]; then
    parent_session=$(tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null |
      awk -v p="$parent" '$1 == p { print $2; exit }')
    if [ -n "$parent_session" ]; then
      new_window=$(tmux new-window -t "$parent_session" -P -F '#{window_id}' "tmux attach-session -t '$session'")
      tmux select-window -c "$parent" -t "$new_window" 2>/dev/null
      exit 0
    fi
  fi

  # Fallback if no parent client is recorded.
  tmux new-window "tmux attach-session -t '$session'"
  exit 0
fi

pane=$(printf '%s' "$sel" | cut -f2)

parent=$(tmux show-options -gqv @pi_parent 2>/dev/null)
session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)

# Move the parent client to the window the session was launched from (best-effort),
# focus the chosen PI's own window inside that session, then attach it in a popup.
origin=$(tmux show-options -qv -t "$session" @pi_origin 2>/dev/null)
[ -n "$origin" ] && [ -n "$parent" ] &&
  tmux switch-client -c "$parent" -t "$origin" 2>/dev/null

tmux select-window -t "$pane" 2>/dev/null
tmux select-pane -t "$pane" 2>/dev/null
tmux attach-session -t "$session"
