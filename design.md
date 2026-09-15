# Signal File Design

## Location

Signal files are stored in `$HOME/.tmux-pi-session-manager/signals/`.
Each signal file is named after the tmux session: `pi-<hash>-<timestamp><random>.signal`.

## Format

Each signal file is a JSON object with the following fields:

- `session`: string, the tmux session name (e.g., "pi-a1b2c3d4-123456789012345")
- `cwd`: string, the current working directory where the PI session was launched
- `workspace`: string, the directory used as the workspace scope for this session.
  This is set to the pane's current path at launch time and drives the picker
  filter so `prefix + u` shows only sessions from the same workspace.
- `origin`: string, the tmux window ID from which the launcher was invoked (we store this for compatibility and to set the session option @pi_origin).
- `pane_id`: string, the tmux pane ID where the PI process is running (the initial pane of the session).
- `created_at`: integer, Unix timestamp when the signal file was created.
- `status`: string, one of "working", "waiting", "idle". The launcher sets it to "working" and the picker refreshes it live by inspecting the pane process tree.

## Example

```json
{
  "session": "pi-a1b2c3d4-123456789012345",
  "cwd": "/home/yareliu/Projects/my-project",
  "workspace": "/home/yareliu/Projects/my-project",
  "origin": "@1",
  "pane_id": "%0",
  "created_at": 1789155000,
  "status": "working",
  "status_at": 1789155000
}
```

## Lifecycle

- When the launcher creates a new tmux session, it creates the signal file with status "working".
- When the tmux session ends, the `session-closed` hook runs `cleanup-session.sh`, which deletes the signal file.
- The picker reads signal files and refreshes each row’s status by inspecting the pane process tree.
