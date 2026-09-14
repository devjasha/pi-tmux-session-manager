#!/usr/bin/env bash
# tmux-pi-session-manager
#
# List, monitor status, and jump across nested PI sessions from a
# single popup. tpm runs this file as an executable on tmux startup; it reads
# user options (with sensible defaults) and installs the key bindings.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

launch_key="$(get_tmux_option @pi_launch_key 'y')"
list_key="$(get_tmux_option @pi_list_key 'u')"
orch_key="$(get_tmux_option @pi_orch_key 'o')"

# Launch (or re-attach to) a PI session for the current pane's directory.
# #{pane_current_path} / #{window_id} are expanded by run-shell before the args
# reach the script.
tmux bind-key "$launch_key" \
  run-shell "$CURRENT_DIR/scripts/launch.sh '#{q:pane_current_path}' '#{q:window_id}'"

# Open the session picker. When pressed from inside a session popup, list.sh
# closes that popup first so the picker opens full-size on the outer client.
tmux bind-key "$list_key" \
  run-shell "$CURRENT_DIR/scripts/list.sh '#{q:client_name}' '#{q:pane_current_path}'"

# Global orchestrator view: all agents across all workspaces.
tmux bind-key "$orch_key" \
  run-shell "$CURRENT_DIR/scripts/orch-menu.sh"

# Forward a bell from a dedicated session to its origin window's pane, so
# tmux's own bell machinery (window-status-bell-style, and terminal
# passthrough when that window is visible) picks it up even though the
# session that rang is a separate session from the origin.
if [ "$(get_tmux_option @pi_forward_bell 'on')" = 'on' ]; then
  tmux set-hook -g alert-bell \
    "run-shell -b \"$CURRENT_DIR/scripts/bell.sh '#{q:hook_session_name}'\""
fi

# Status-bar indicator: shows counts of sessions waiting for input or idle.
if [ "$(get_tmux_option @pi_status_indicator 'on')" = 'on' ]; then
  current_status_right="$(tmux show-options -gqv status-right)"
  saved_original="$(tmux show-options -gqv @pi_status_right_original 2>/dev/null)"

  # Save the pristine value once so reloads don't nest the indicator.
  if [ -z "$saved_original" ]; then
    tmux set-option -g @pi_status_right_original "$current_status_right"
    saved_original="$current_status_right"
  fi

  # Inject the indicator command only if it is not already present.
  case "$current_status_right" in
    *"$CURRENT_DIR/scripts/status.sh"*) ;;
    *)
      if [ -n "$saved_original" ]; then
        tmux set-option -g status-right "#($CURRENT_DIR/scripts/status.sh) $saved_original"
      else
        tmux set-option -g status-right "#($CURRENT_DIR/scripts/status.sh)"
      fi
      ;;
  esac

  # Refresh often enough to be useful, without overriding a faster user setting.
  current_interval="$(tmux show-options -gqv status-interval)"
  if [ -z "$current_interval" ] || [ "$current_interval" -gt 5 ] 2>/dev/null; then
    tmux set-option -g status-interval 5
  fi
fi
