# tmux-pi-session-manager

Launch, list, and jump across PI coding-agent sessions from inside tmux.

Inspired by [tmux-claude-session-manager](https://github.com/bdx0/tmux-claude-session-manager).

## Requirements

- tmux ≥ 3.2 (for `display-popup`)
- [fzf](https://github.com/junegunn/fzf)
- [jq](https://jqlang.github.io/jq/)
- `pi` command on your `PATH`

## Installation

### TPM

Add to your `~/.tmux.conf`:

```tmux
set -g @plugin 'devjasha/tmux-pi-session-manager'
```

Then press `prefix + I` to install.

### Manual

Clone into your tmux plugins directory:

```bash
git clone https://github.com/devjasha/tmux-pi-session-manager \
  ~/.tmux/plugins/tmux-pi-session-manager
```

Then source it in `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-pi-session-manager/tmux-pi-session-manager.tmux
```

## Key bindings

| Key | Action |
|-----|--------|
| `prefix + y` | Launch (or re-attach to) a PI session for the current pane's directory |
| `prefix + u` | Open the session picker (`fzf`) for the current workspace |

Inside the picker:
- `Enter` — jump to the selected agent
- `Ctrl-x` — kill the selected agent
- `Ctrl-c` — close the picker

## Workspaces

Every PI session is scoped to a **workspace** — the directory you were in when
you launched it with `prefix + y`. When you open the picker with `prefix + u`,
it only shows sessions belonging to the same workspace as the pane you pressed
it from. This keeps sessions organized per folder so you never see unrelated
agents cluttering the list.

*Example:* If you launch a session from `~/Projects/frontend` and later another
from `~/Projects/backend`, pressing `prefix + u` inside `~/Projects/frontend`
will show only the frontend session.

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `@pi_session_prefix` | `pi-` | Prefix for tmux session names |
| `@pi_command` | `pi` | Command to start the agent |
| `@pi_args` | `''` | Extra arguments for the command |
| `@pi_popup_width` | `90%` | Popup width |
| `@pi_popup_height` | `90%` | Popup height |
| `@pi_signal_dir` | `~/.tmux-pi-session-manager/signals` | Directory for agent status files |
| `@pi_launch_key` | `y` | Key binding to launch a session |
| `@pi_list_key` | `u` | Key binding to open the picker |
| `@pi_forward_bell` | `on` | Forward bell events from PI sessions to their origin windows |
| `@pi_fzf_options` | `''` | Extra fzf options |

Example in `~/.tmux.conf`:

```tmux
set -g @pi_command 'pi'
set -g @pi_args '--model gpt-4o'
set -g @pi_popup_width '80%'
set -g @pi_popup_height '80%'
```
