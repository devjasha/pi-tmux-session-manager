# Research: PI Session Lifecycle

## How PI Sessions Work

When you run `pi` without `--no-session`, it creates a session and stores it as a JSONL file under `~/.pi/agent/sessions/`. The session file is named with a timestamp and optionally a session ID if provided via `--session-id` or `--session`.

The session file accumulates all events (messages, model changes, tool calls, etc.) and is not deleted when the `pi` process exits. Therefore, the existence of a session file does not indicate whether the PI process is currently running.

## Detecting Active PI Sessions

To know if a PI session is currently active (i.e., there is a running `pi` process), we must rely on something else. Since we launch PI inside a tmux session (as the original plugin does), we can consider that the tmux session exists while the PI process is running inside it (assuming we run `pi` as the sole command in the tmux session and do not set `remain-on-exit`).

Thus, we can use the presence of a tmux session with a specific naming pattern as the indicator of an active PI agent.

## Signal File Approach

Given that we need to associate each PI agent with a tmux session and possibly store additional metadata (like the current working directory, origin window, etc.), we can create a signal file for each agent when we launch it and remove it when the tmux session ends (i.e., when the PI process exits).

The signal file can contain:
- TMux session name
- Current working directory (hash or path)
- Origin window/pane information (for jumping back)
- Timestamp of creation
- Possibly status (if we can determine it)

However, determining granular status (working/waiting/idle) from outside PI is challenging without hooks into PI's internal state.

### Possible Status Approximations

1. **Binary Status**: Active (tmux session exists) vs Inactive (no tmux session). This is simple and reliable.

2. **Activity-based Status**: By examining the PI session file's recent timestamps, we could infer:
   - `working`: if there has been a message or tool call in the last N seconds (e.g., 30s)
   - `waiting`: if the last activity was longer ago but still within a threshold (e.g., 5 minutes)
   - `idle`: if no activity for a long time

   This requires reading the session file for each agent, which could be heavy if there are many agents, but we can cache or limit the number.

3. **PI-provided Status**: If PI ever provides a command to list agents with status (like `claude agents --json`), we could use that. Currently, no such command exists.

Given the constraints, we propose to implement binary status initially, and if time permits, explore activity-based status by parsing the session file.

## Launching PI in Tmux

The launcher script should:
1. Determine a unique identifier for the current directory (or given directory).
2. Check if a tmux session with the name `pi-<hash>` already exists.
   - If yes, attach to it (or just switch to it) and update the signal file if needed.
   - If no, create a new detached tmux session, set up the signal file, record the origin pane, and start `pi` inside the tmux session.
3. The tmux session should run `pi` (possibly with arguments to load the current directory context) and exit when `pi` exits.

## Signal File Location

We can store signal files in a directory like `~/.tmux-pi-session-manager/signals/` or under `~/.pi/agent/` to keep things together.

## Conclusion

For the MVP, we will implement:
- Launcher that creates a tmux session per directory running `pi`.
- Signal file to track active agents (created on launch, removed on tmux session end).
- Lister that reads signal files and outputs JSON for the picker.
- Picker that uses fzf to list agents, show live previews (via tmux capture-pane), and handle jump/kill.
- Bell forwarding hook to relay bells from PI sessions to origin windows.

Status will be binary: "active" if signal file exists (or tmux session exists). We'll display it as "working" for simplicity, or we can show a dot.

