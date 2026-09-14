#!/usr/bin/env bash
# Global orchestrator view: all agents across all workspaces.
#
# Refreshes health status, then opens the picker without workspace filtering
# so every managed PI session is visible regardless of where it was launched.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# Run a health pass in the background so the picker sees fresh state.
"$DIR/orch.sh" health >/dev/null 2>&1 &

w="$(get_tmux_option @pi_popup_width '90%')"
h="$(get_tmux_option @pi_popup_height '90%')"

tmux display-popup -w "$w" -h "$h" -E "$DIR/picker.sh"
