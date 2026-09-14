# Signal File Design

## Location
Signal files will be stored in `$HOME/.tmux-pi-session-manager/signals/`.
Each signal file is named after the tmux session: `pi-<hash>.signal`.

## Format
Each signal file is a JSON object with the following fields:

- `session`: string, the tmux session name (e.g., "pi-a1b2c3d4")
- `cwd`: string, the current working directory where the PI session was launched
- `workspace`: string, the directory used as the workspace scope for this session.
  This is set to the pane's current path at launch time and drives the picker
  filter so `prefix + u` shows only sessions from the same workspace.
- `origin`: string, the tmux window ID from which the launcher was invoked (we store this for compatibility and to set the session option @pi_origin).
- `pane_id`: string, the tmux pane ID where the PI process is running (the initial pane of the session).
- `created_at`: integer, Unix timestamp when the signal file was created.
- `status`: string, one of "working", "waiting", "idle". For now, we will set it to "working" when the session is launched and leave it as such. We may update it later based on activity.

## State Transitions
- When the launcher creates a new tmux session, it creates the signal file with status "working".
- When the tmux session ends (i.e., the PI process exits), the signal file is removed by a tmux hook (e.g., `session-stopped`).
- We do not currently update the status based on PI activity; we leave it as "working". In the future, we could update the signal file periodically from within the PI session (by writing a status file inside the session's working directory and having a background job update the signal file), but for MVP we keep it simple.

## Example
```json
{
  "session": "pi-a1b2c3d4",
  "cwd": "/home/yareliu/Projects/my-project",
  "workspace": "/home/yareliu/Projects/my-project",
  "origin": "@1",
  "pane_id": "%0",
  "created_at": 1789155000,
  "status": "working"
}
```

# Status-Bar Notification Feature

## Overview
The plugin can display a small, live-updating indicator in the tmux `status-right` area that alerts the user whenever any managed PI session is either:
- **waiting** — the `pi` process is in a sleep / blocked state (likely needs user input)
- **idle** — the `pi` process is no longer running in the pane (task finished)

`working` sessions are intentionally *not* shown because they do not require attention.

## Mechanism
A new helper script `scripts/status.sh` scans the signal-file directory, counts how many sessions are in each attention-requiring state, and prints a compact tmux-formatted string.  The main plugin entry-point (`tmux-pi-session-manager.tmux`) optionally prepends this script to the user's `status-right` option via tmux's `#(...)` interpolation.  Tmux re-evaluates `#(...)` every `status-interval` seconds.

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `@pi_status_indicator` | `on` | Master switch. When `on`, the plugin injects the indicator into `status-right` and sets a sensible `status-interval`. When `off`, nothing is changed. |
| `@pi_status_waiting_color` | `yellow` | tmux colour used for the waiting count segment. |
| `@pi_status_idle_color` | `green` | tmux colour used for the idle / completed count segment. |
| `@pi_status_waiting_format` | `#[fg={color}]⏸ {count}#[default]` | Format string for waiting sessions. `{color}` and `{count}` are substituted at runtime. |
| `@pi_status_idle_format` | `#[fg={color}]✔ {count}#[default]` | Format string for idle sessions. Same placeholders. |
| `@pi_status_separator` | ` \| ` | Text placed between the waiting and idle segments when both are present. |

## Behaviour Details
- On first load the plugin stores the current `status-right` value in `@pi_status_right_original` so subsequent reloads do not nest the indicator.
- The indicator is only injected if `status-right` does not already contain `status.sh`.
- `status-interval` is raised to `5` (if it is currently unset or slower) so the bar updates reasonably often without overriding an already-fast user setting.
- `status.sh` cleans up stale signal files (sessions that no longer exist) as a side effect, keeping the signal directory tidy.
- When no sessions need attention the script prints nothing, keeping `status-right` clean.

## Future Enhancements
- Per-session readiness timestamps so the indicator can show "1 new" vs "1 old".
- Clickable `#(...)` output that opens the picker, if tmux ever adds clickable status segments.
- Optional `#(curl)`-based push notification integration for out-of-band alerts.
