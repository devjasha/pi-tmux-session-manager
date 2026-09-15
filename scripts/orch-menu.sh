#!/usr/bin/env bash
# Global orchestrator view: all agents across all workspaces.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

w="$(get_tmux_option @pi_popup_width '90%')"
h="$(get_tmux_option @pi_popup_height '90%')"

tmux display-popup -w "$w" -h "$h" -E "$DIR/picker.sh"
