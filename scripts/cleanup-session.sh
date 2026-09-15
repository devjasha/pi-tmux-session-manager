#!/usr/bin/env bash
# Clean up the signal file for a managed session when it closes.
# Called by the session-closed tmux hook.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

session="${1:-}"
[ -n "$session" ] || exit 0

prefix="$(get_tmux_option @pi_session_prefix 'pi-')"
signal_dir="$(get_tmux_option @pi_signal_dir "$HOME/.tmux-pi-session-manager/signals")"

# Only clean up sessions this plugin manages.
case "$session" in
"$prefix"*)
  rm -f "$signal_dir/${session}.signal"
  rm -f "$HOME/.tmux-pi-session-manager/queue/${session}"
  ;;
esac
