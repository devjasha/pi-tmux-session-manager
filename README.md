<img width="1604" height="1036" alt="Screenshot 2026-09-14 at 14 29 17" src="https://github.com/user-attachments/assets/885577cd-3849-477f-9920-b153a39fcd95" />

# tmux-pi-session-manager

Launch, list, monitor, and jump across [PI coding-agent](https://github.com/earendil-works/pi-coding-agent) sessions from inside tmux.

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
| `prefix + y` | Launch a new PI session for the current pane's directory |
| `prefix + u` | Open the session picker (`fzf`) for the current workspace |
| `prefix + O` | Open the global orchestrator view (all workspaces) |

### Picker controls

| Key | Action |
|-----|--------|
| `Enter` | Jump to the selected agent |
| `Ctrl-p` | Pause or resume the selected agent |
| `Ctrl-x` | Kill the selected agent |
| `Ctrl-c` | Close the picker |

## Workspaces

Every PI session is scoped to a **workspace** — the directory you were in when
you launched it with `prefix + y`. When you open the picker with `prefix + u`,
it only shows sessions belonging to the same workspace as the pane you pressed
it from. This keeps sessions organized per folder so you never see unrelated
agents cluttering the list.

*Example:* If you launch a session from `~/Projects/frontend` and later another
from `~/Projects/backend`, pressing `prefix + u` inside `~/Projects/frontend`
will show only the frontend session.

The current workspace is displayed as a word-wrapped footer at the bottom of
the picker.

## Picker columns

Each row in the picker shows:

| Column | Description |
|--------|-------------|
| ● status | **Red** = actively working, **Yellow** = waiting for input, **Green** = idle, **Purple ⏸** = paused |
| `+N` | Sub-agent count (small gray badge when the PI agent has spawned child agents) |
| task | Optional task description set via the orchestrator |
| Age | Minutes since the session was launched |
| Location | tmux `session:window.pane` where the agent lives |
| Path | Working directory (with `~` shorthand for home) plus git branch info |

## Git worktrees & collision detection

When a PI session is inside a git repository, the picker shows the current
branch next to the path (e.g. `~/proj [feat-branch]`). If `HEAD` is detached,
a short sha is shown instead.

If two or more agents share the same git worktree (same top-level directory),
their rows are marked with a `⚠️` collision badge and the picker header shows
the total number of colliding agents. This makes it easy to spot when multiple
agents are operating in the same workspace so you can avoid stepping on each
other's changes.

## Orchestrator

The orchestrator gives you lifecycle control over every running PI agent
regardless of which workspace launched it.

### Global view (`prefix + o`)

`prefix + o` opens the same picker as `prefix + u`, but it shows **all**
managed PI sessions across every workspace. It also refreshes each session's
health status before opening so the state is current.

### Pause and resume

Press `Ctrl-p` on any row in the picker to toggle pause / resume for that
agent. When paused, the pi process receives `SIGSTOP`; when resumed, it receives
`SIGCONT`. The pause state is persisted in the signal file so it survives
picker refreshes.

Paused agents are excluded from the status-bar indicator because they do not
need attention.

### Task descriptions

You can annotate an agent with a task description. This appears in the picker
next to the status icon so you remember what each agent is working on.

### Command-line orchestrator

Every orchestrator action is also available as a shell command via
`scripts/orch.sh`:

```bash
# Refresh cached status for all sessions
orch.sh health

# Pause / resume / toggle a session
orch.sh pause pi-abc123
orch.sh resume pi-abc123
orch.sh toggle pi-abc123

# Kill a session (escalates SIGTERM → SIGKILL)
orch.sh kill pi-abc123

# Queue input to send when the agent is idle
orch.sh queue pi-abc123 "Implement user auth"
orch.sh send pi-abc123

# Set a task description
orch.sh set-task pi-abc123 "Refactor login flow"

# Show detailed JSON status
orch.sh status pi-abc123

# Remove stale signal files
orch.sh cleanup
```

## Status-bar indicator

The plugin can display a live-updating indicator in your tmux `status-right`
showing how many PI sessions need attention:

- **⏸** (yellow) — sessions where the `pi` process is sleeping / blocked
  (likely waiting for user input)
- **✔** (green) — sessions where `pi` has finished running (idle)

Sessions where `pi` is actively working are omitted from the indicator since
they don't need attention. Tmux refreshes the indicator every `status-interval`
(defaults to 5 seconds when enabled).

| Option | Default | Description |
|--------|---------|-------------|
| `@pi_status_indicator` | `on` | Master switch for the status-right indicator |
| `@pi_status_waiting_color` | `yellow` | tmux colour for the waiting count |
| `@pi_status_idle_color` | `green` | tmux colour for the idle count |
| `@pi_status_waiting_format` | `#[fg={color}]⏸ {count}#[default]` | Format string for waiting count (`{color}`, `{count}` substituted) |
| `@pi_status_idle_format` | `#[fg={color}]✔ {count}#[default]` | Format string for idle count |
| `@pi_status_separator` | ` \| ` | Separator between waiting and idle segments |

## Bell forwarding

Bells (e.g. from `\a` in terminal output) rung inside a dedicated PI session
are forwarded to the original tmux window that launched it. This works with
tmux's built-in bell styling (`window-status-bell-style`) and terminal
passthrough, so you never miss when an agent completes a long task.

Disabled by setting `@pi_forward_bell off`.

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
| `@pi_orch_key` | `O` | Key binding to open the global orchestrator view |
| `@pi_forward_bell` | `on` | Forward bell events from PI sessions to their origin windows |
| `@pi_fzf_options` | `''` | Extra fzf options |
| `@pi_status_indicator` | `on` | Show PI session status in tmux status-right |
| `@pi_status_waiting_color` | `yellow` | Colour for waiting count in status-right |
| `@pi_status_idle_color` | `green` | Colour for idle count in status-right |
| `@pi_status_waiting_format` | `#[fg={color}]⏸ {count}#[default]` | Format string for waiting sessions |
| `@pi_status_idle_format` | `#[fg={color}]✔ {count}#[default]` | Format string for idle sessions |
| `@pi_status_separator` | ` \| ` | Separator between status segments |

Example in `~/.tmux.conf`:

```tmux
set -g @pi_command 'pi'
set -g @pi_args '--model gpt-4o'
set -g @pi_popup_width '80%'
set -g @pi_popup_height '80%'
set -g @pi_status_indicator 'on'
```