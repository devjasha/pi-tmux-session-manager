# Signal File Design

## Location
Signal files will be stored in `$HOME/.tmux-pi-session-manager/signals/`.
Each signal file is named after the tmux session: `pi-<hash>.signal`.

## Format
Each signal file is a JSON object with the following fields:

- `session`: string, the tmux session name (e.g., "pi-a1b2c3d4")
- `cwd`: string, the current working directory where the PI session was launched
- `origin`: string, the tmux window ID from which the launcher was invoked (we store this for compatibility and to set the session option @pi_origin).
- `pane_id`: string, the tmux pane ID where the PI process is running (the initial pane of the session).
- `created_at`: integer, Unix timestamp when the signal file was created.
- `status`: string, one of "working", "waiting", "idle". For now, we will set it to "working" when the session is launched and leave it as such. We may update it later based on activity.

## State Transitions
- When the launcher creates a new tmux session, it creates the signal file with status "working".
- When the tmux session ends (i.e., the PI process exits), the signal file is removed by a tmux hook (e.g., `session-stopped`).
- We do not currently update the status based on PI activity; we leave it as "working". In the future, we could update the signal file periodically from within the PI session (by writing a status file inside the session's working directory and having a background job update the signal file), but for MVP we keep it simple.

## Example
{
  "session": "pi-a1b2c3d4",
  "cwd": "/home/yareliu/Projects/my-project",
  "origin": "@1",
  "pane_id": "%0",
  "created_at": 1789155000,
  "status": "working"
}
