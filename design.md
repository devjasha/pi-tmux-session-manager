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
- **running in this session** — the `pi` process is alive in the same tmux session the user is currently attached to (working or waiting, but not idle or paused)
- **waiting** — the `pi` process is in a sleep / blocked state (likely needs user input)
- **idle** — the `pi` process is no longer running in the pane (task finished)

`working` sessions are intentionally *not* shown in the waiting/idle segments because they do not require attention, but they *are* counted in the per-session running segment because they are still active agents in the current session.

## Mechanism
A new helper script `scripts/status.sh` scans the signal-file directory, counts how many sessions are in each relevant state, and prints a compact tmux-formatted string.  When the per-session indicator is enabled, `tmux-pi-session-manager.tmux` passes the current tmux session name (`#{q:session_name}`) to `status.sh` so it can count only signal files whose `session` field matches.  The main plugin entry-point optionally prepends this script to the user's `status-right` option via tmux's `#(...)` interpolation.  Tmux re-evaluates `#(...)` every `status-interval` seconds.

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `@pi_status_indicator` | `on` | Master switch. When `on`, the plugin injects the indicator into `status-right` and sets a sensible `status-interval`. When `off`, nothing is changed. |
| `@pi_status_session_indicator` | `on` | Show the count of agents currently running in the current tmux session. |
| `@pi_status_session_color` | `cyan` | tmux colour used for the per-session running count segment. |
| `@pi_status_session_format` | `#[fg={color}]▶ {count}#[default]` | Format string for the per-session running count. `{color}` and `{count}` are substituted at runtime. |
| `@pi_status_waiting_color` | `yellow` | tmux colour used for the waiting count segment. |
| `@pi_status_idle_color` | `green` | tmux colour used for the idle / completed count segment. |
| `@pi_status_waiting_format` | `#[fg={color}]⏸ {count}#[default]` | Format string for waiting sessions. `{color}` and `{count}` are substituted at runtime. |
| `@pi_status_idle_format` | `#[fg={color}]✔ {count}#[default]` | Format string for idle sessions. Same placeholders. |
| `@pi_status_separator` | ` \| ` | Text placed between segments when more than one is present. |

## Behaviour Details
- On first load the plugin stores the current `status-right` value in `@pi_status_right_original` so subsequent reloads do not nest the indicator.
- The indicator is injected if `status-right` does not already contain the current `status.sh` command; if it contains the older global-only command, the plugin migrates it to the per-session format.
- When `@pi_status_session_indicator` is `on`, `tmux-pi-session-manager.tmux` invokes `status.sh` with the current tmux session name (`#{q:session_name}`). Setting `@pi_status_session_indicator` to `off` disables the per-session segment and restores the global-only indicator.
- `status-interval` is raised to `5` (if it is currently unset or slower) so the bar updates reasonably often without overriding an already-fast user setting.
- `status.sh` cleans up stale signal files (sessions that no longer exist) as a side effect, keeping the signal directory tidy.
- When no sessions need attention and no agents are running in the current session, the script prints nothing, keeping `status-right` clean.

## Future Enhancements
- Per-session readiness timestamps so the indicator can show "1 new" vs "1 old".
- Clickable `#(...)` output that opens the picker, if tmux ever adds clickable status segments.
- Optional `#(curl)`-based push notification integration for out-of-band alerts.
