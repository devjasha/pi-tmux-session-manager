#!/usr/bin/env bash
# Launch (or re-attach to) a PI session for a directory, shown in a popup.
# Args: <dir> [origin-window-id]   (both expanded by run-shell in the binding)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

path="${1:-$PWD}"
window="${2:-}"

# Get tmux options with defaults
prefix="$(get_tmux_option @pi_session_prefix 'pi-')"
cmd="$(get_tmux_option @pi_command 'pi')"
args="$(get_tmux_option @pi_args '')"
[ -n "$args" ] && cmd="$cmd $args"
w="$(get_tmux_option @pi_popup_width '90%')"
h="$(get_tmux_option @pi_popup_height '90%')"
signal_dir="$(get_tmux_option @pi_signal_dir $HOME/.tmux-pi-session-manager/signals)"

# Ensure signal directory exists
mkdir -p "$signal_dir"

session="${prefix}$(session_hash "$path")"
workspace="$(normalize_path "$path")"

# If we are already inside a popup session (i.e., the current session starts with the prefix), do not open another popup.
if [[ "$(tmux display-message -p '#S')" == "$prefix"* ]]; then
  tmux display-message '🫪 Popup window already open'
  exit 0
fi

# Check if the tmux session already exists
if ! tmux has-session -t "$session" 2>/dev/null; then
  # Session does not exist, create it
  [ -d "$path" ] || {
    tmux display-message "tmux-pi-session-manager: $path no longer exists"
    exit 0
  }
  # Create a new detached session
  tmux new-session -d -s "$session" -c "$path" "$cmd"
  # Get the pane ID of the first pane in the new session
  pane_id=$(tmux display-message -p -t "$session" '#{pane_id}')
  # Create signal file
  signal_file="${signal_dir}/${session}.signal"
  origin_window="${window:-$(tmux display-message -p '#{window_id}')}"
  cat > "$signal_file" <<EOJSON
{
  "session": "${session}",
  "cwd": "${path}",
  "workspace": "${workspace}",
  "origin": "${origin_window}",
  "pane_id": "${pane_id}",
  "created_at": $(date +%s)
}
EOJSON
else
  # Session exists, we may want to update the origin window? Not necessary.
  # But we should ensure the signal file exists and is valid.
  signal_file="${signal_dir}/${session}.signal"
  if [ ! -f "$signal_file" ]; then
    # Signal file missing, recreate it
    # We need to get the pane ID and origin window.
    # For pane ID, we take the first pane's ID? We'll get the active pane? 
    # Instead, we can try to get the pane ID from the session's initial pane? 
    # Since we don't have it stored, we'll get the pane ID of the first pane.
    pane_id=$(tmux display-message -p -t "$session" '#{pane_id}')
    origin_window="${window:-$(tmux display-message -p '#{window_id}')}"
    cwd="$(tmux display-message -p -t "$session" '#{pane_current_path}')"
    cat > "$signal_file" <<EOJSON
{
  "session": "${session}",
  "cwd": "${cwd}",
  "workspace": "${workspace}",
  "origin": "${origin_window}",
  "pane_id": "${pane_id}",
  "created_at": $(date +%s)
}
EOJSON
  fi
fi

# Record which window launched it, so the picker can jump back here later.
# Store in session option @pi_origin (only if window is provided)
[ -n "$window" ] && tmux set-option -t "$session" @pi_origin "$window"

# Store workspace on the session so the picker can filter by it even
# after the signal file may have been cleaned up.
tmux set-option -t "$session" @pi_workspace "$workspace"

# Attach to the session in a popup
tmux display-popup -w "$w" -h "$h" -E "tmux attach-session -t '$session'"
