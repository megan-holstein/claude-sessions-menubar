# claude-sessions-menubar

This is a fork of [thekasmira/claude-agent-menubar](https://github.com/thekasmira/claude-agent-menubar), changed so that the marks say what you have to do next instead of what the agent is doing.

A macOS menu bar indicator for every Claude Code session running on your
Mac. It shows what each session is doing right now, and clicking one
focuses its terminal tab.

```
🔴1 🟢2 ⏳3                        <- menu bar
├── 🔴 my-api             needs your answer  3m
├── 🟢 claude-sessions-menubar  finished  2m
├── 🟢 website            finished  14m
├── ⏳ Refactor auth middleware  working · 2 subagents  48s
├── ⏳ billing            working  1m
└── ⏳ release            waiting on 1 subagent, 1 background task  9m
```

## The four marks

The marks describe what *you* have to do, loudest first. The menu bar shows one count per mark present, in this order, and the dropdown is one flat list in the same order, oldest first within a mark.

| Mark | Text | Meaning |
|---|---|---|
| 🔴 | needs your answer | **Act now.** A permission prompt, a question dialog or a plan approval is blocking the session. |
| 🟢 | finished | **Your turn.** The main loop finished, no subagent is live and no background task is running. |
| ⏳ | working, or waiting on … | **Nothing to do yet.** Either the main loop is working (with live subagents the text reads `working · N subagents`), or the main loop finished but subagents or background tasks are still running (`waiting on 2 subagents`, `waiting on 1 background task` or `waiting on 1 subagent, 2 background tasks`). Both share one mark and one count because neither asks anything of you; the row text says which it is. |
| ⚪ | new, nothing asked yet | The session opened and has not received a prompt. |

With no sessions the title reads `Claude: none`. The dropdown ends with a grey legend of the four marks.

The plugin derives the mark from the record the hook writes (`main`, `subagents`) plus a count of background tasks, in one pure function (`classify` in the plugin). 🟢 means finished, not healthy: green is the cue to go and look.

### Question dialogs

`AskUserQuestion` and `ExitPlanMode` open a dialog that fires no `Notification`, so a session blocked on one used to show as working. The hook now treats a main-context `PreToolUse` for either tool as `needs_input` and records the message `Claude asked you a question` or `Claude is waiting for you to approve a plan`. The next main-context `PreToolUse`, `UserPromptSubmit` or `Stop` moves the session on and clears the message. A subagent's tool calls do not clear a question the main loop is still asking.

### Silent sessions

A ⏳ session with no hook event of any kind for an hour may be hung, so its row ends with an amber pill giving the whole hours since its last event (`1 hr`, `2 hr`). The time comes from the record's `updated_at`, which every hook event moves, a subagent's included, so a session that is really working keeps resetting it. A long background task fires no events, so it can earn a pill while still running; the pill says to look, not that the session is dead. 🔴 and 🟢 rows never get one, since they are already waiting on you. The threshold is `SILENT_AFTER` in the plugin.

### Background tasks

Claude Code's Bash tool runs each command as a direct child of the `claude` process, with a command line that contains `/.claude/shell-snapshots/snapshot-`. A `run_in_background` task or a Monitor watcher keeps such a child alive after the turn ends. On each refresh the plugin makes one `/bin/ps -Ao ppid=,args=` call and counts those children per `claude` pid. The count changes the mark only when `main` is `done` or `idle`, because a foreground Bash call is normal while the main loop works. If the `ps` call fails, the count is 0.

## Install

1. Get the code:
   ```bash
   git clone https://github.com/megan-holstein/claude-sessions-menubar.git claude-sessions-menubar
   cd claude-sessions-menubar
   ```
2. Run the installer:
   ```bash
   ./install.sh
   ```

`install.sh` is safe to re-run. It will:

* check you're on macOS with Homebrew installed
* install SwiftBar (`brew install --cask swiftbar`) if it isn't already
* check for `jq` and install it via Homebrew if missing
* copy this folder to `~/.claude/claude-sessions-menubar/` (its permanent home — skipped
  if you're already running it from there, or if it detects hooks already
  registered elsewhere on this machine)
* point SwiftBar at the bundled plugin — either by setting SwiftBar's plugin
  directory (only if none is set yet) or by linking the plugin into your
  existing SwiftBar plugin directory, so it never hijacks a setup you already
  have
* merge the required hooks into `~/.claude/settings.json`, backing it up
  first (skipped if they're already there — running it twice never creates
  duplicate entries)
* launch SwiftBar

After it finishes, restart any Claude Code sessions that were already open
(or just keep working — Claude Code re-reads `settings.json` while running,
so most sessions pick the hooks up on their next event without a restart).

### Automation permission

The **first** time you click a session in the menu, macOS will show an
"claude-sessions-menubar wants to control Terminal" (or iTerm) prompt. Approve it —
that permission is what lets `focus-tab.sh` find and raise the right tab.
You'll see this prompt once per terminal app.

### Supported terminals for click-to-focus

| Terminal | Click-to-focus |
|---|---|
| Terminal.app | ✅ |
| iTerm2 | ✅ |
| VS Code integrated terminal, Ghostty, tmux, SSH sessions, etc. | Shows up in the list and is tracked normally, but clicking it shows a "not found" notification — these apps don't expose an AppleScript tab/tty API the same way. |

## Uninstall

```bash
./uninstall.sh
```

This removes the hook entries from `~/.claude/settings.json` (backing it up
first), removes the plugin file/symlink from SwiftBar's plugin directory, and
deletes `~/.claude/agent-status/`. It leaves SwiftBar itself installed and
prints the commands to remove it too, and leaves the installed folder
(`~/.claude/claude-sessions-menubar/`) in place for you to delete by hand.

## How it works

Four pieces, no daemon and no database:

1. **`hook.sh`** — the launcher registered on nine Claude Code hook events in
   `~/.claude/settings.json`. It does nothing but run `hook-impl.sh` and always
   exit 0, because a hook that exits 2 (which bash does on a syntax error)
   blocks the tool call or session it's attached to — machine-wide — so
   keeping the launcher trivial means a bad edit to the implementation only
   ever degrades the menu bar, never Claude Code itself.
2. **`hook-impl.sh`** — the actual logic. Every event writes/updates one small
   JSON record at `~/.claude/agent-status/<session_id>.json`, tracking two
   things independently: `main` (the top-level agent loop's own state) and
   `agents` (the set of live subagents, keyed by `agent_id`, added by
   `SubagentStart` and removed by `SubagentStop`). Events from inside a
   subagent carry `agent_id`/`agent_type` and never move `main` or the
   session's `cwd` label; a `SubagentStop` for an id this session never saw
   start — Claude Code's own internal helper agents — is ignored rather than
   guessed at. Because a hook runs as a child of the `claude` process, it can
   also walk up its own ancestor chain to find that process and record its
   **pid**, **tty**, and hosting **terminal app** — what's needed to prove the
   session is alive and to find its tab later. (`tty` on the hook's own stdin
   is useless: stdin is a pipe.) Every event is also appended to
   `~/.claude/agent-status/events.log` (rotated at 512 KB) as a debugging aid
   — set `CLAUDE_AGENT_STATUS_LOG=0` to disable it.
3. **`plugins/claude-sessions.5s.py`** — a SwiftBar plugin that re-reads those
   records every 5 seconds, derives each session's mark and renders the menu.
4. **`focus-tab.sh <tty> [terminal]`** — AppleScript that walks the hosting
   terminal app's windows and tabs, finds the tab whose `tty` matches, selects
   it, and raises the window. Dispatches to a Terminal.app or iTerm2 script
   depending on the recorded terminal app. The Terminal.app script activates
   Terminal first, un-minimizes the window if needed, and addresses it by its
   `id`: AppleScript's loop variable is a positional reference (`window 2`),
   so after the window order changes it names a different window.

Records are the only shared state, so nothing needs to be restarted or kept in
sync. A record is created by whichever event fires first and deleted on
`SessionEnd`; anything the plugin finds pointing at a dead process is deleted on
the next refresh.

### Session names

Each session's label is picked with this precedence: a custom name you set
with `/rename` in that session, otherwise Claude Code's auto-generated
conversation title (read from the session's transcript), otherwise the
project folder name.

## State model

Two things are tracked independently and combined into the displayed `state`:

**`main`** — what the top-level agent loop is doing. Moved **only** by events
from the main context (payloads without an `agent_id`):

| `main` | Set by | Meaning |
|---|---|---|
| `idle` | `SessionStart` | Session opened, nothing asked of it yet |
| `working` | `UserPromptSubmit`, `PreToolUse` (main context) | Claude is actively doing something |
| `done` | `Stop` | The main loop ended its turn |
| `needs_input` | `PermissionRequest` (any context), `Notification`, or a main-context `PreToolUse` of `AskUserQuestion` / `ExitPlanMode` | Permission prompt, elicitation dialog, question or plan approval — **you are blocking it** |
| *(deleted)* | `SessionEnd` | Record removed |

**`agents`** — the set of live subagents, keyed by `agent_id`. `SubagentStart`
adds one; `SubagentStop` removes it **only if the id is known** (Claude Code
also emits `SubagentStop` for its internal helper agents, with an empty
`agent_type` and ids that never started — those are ignored); any other event
carrying an `agent_id` self-heals a missing entry and refreshes its `seen`
timestamp; an entry silent for an hour is pruned as a missed stop.

Stored `state` = `needs_input` if `main` is `needs_input` → else `subagents` if any agent is live → else `main`. The plugin does not draw `state` directly: it derives the mark from `main`, the subagent count and the background-task count (see "The four marks"). `Stop` fires the instant the orchestrator ends its turn, even with background agents still going, which is why 🟢 requires both a finished main loop and nothing running underneath.

Two details worth knowing:

* **`state_since` only moves when the state actually changes.** Ten `PreToolUse`
  events in a row keep one "working since" timestamp, so the elapsed time in the
  menu answers "how long has it been like this", not "how long since the last
  event".
* **Informational notifications don't fake a prompt.** `auth_success`,
  `agent_completed` and the `quota_auto_resume_*` types leave the state and any
  pending prompt text untouched — otherwise a background auth refresh would
  clear the real permission prompt you still need to answer.

### Record shape

```json
{
  "session_id": "6781f9fd-…", "pid": 57421, "tty": "ttys004",
  "terminal": "Apple_Terminal",
  "cwd": "/Users/you/dev/claude-sessions-menubar", "project": "claude-sessions-menubar",
  "state": "subagents", "main": "done", "state_since": 1788813153,
  "last_event": "PreToolUse (general-purpose)",
  "started_at": 1788813153, "updated_at": 1788813180,
  "agents": {
    "a8bb627f38ba116a4": {"type": "general-purpose", "since": 1788813160, "seen": 1788813180}
  },
  "subagents": 1,
  "message": "…", "notification_type": "permission_prompt"
}
```

`terminal` comes from the hosting terminal's `$TERM_PROGRAM` and is only as
reliable as that environment variable (Apple_Terminal, iTerm.app, vscode,
ghostty, ...). `message` / `notification_type` are present only while `state`
is `needs_input`.

## Menu items

* **Click a session** → focuses its tab (Terminal.app / iTerm2 only, see above),
  un-minimizing the window if needed. A session row has no submenu: macOS menus
  do not reliably run the action of an item that also opens a submenu.
* **Open status folder** → opens `~/.claude/agent-status`.
* **Clear stale** → forces a prune of dead and unparseable records.

## Known limits

* **Sessions that were already running may not appear until they restart.**
  Claude Code re-reads `settings.json` while running, so in practice sessions
  often pick the hooks up immediately — but a session that never fires another
  event won't register until it does.
* **Only Terminal.app and iTerm2 support click-to-focus.** Sessions in VS
  Code, Ghostty, tmux or over SSH still appear in the list (state tracking is
  terminal-agnostic) but clicking them reports that no matching tab was
  found. tmux is the awkward case: the tty recorded is the pane's, which
  neither app has ever heard of.
* **🔴 `needs_input` only means a real dialog.** `PermissionRequest`, the `permission_prompt` and `elicitation_dialog` notifications, and the `AskUserQuestion` and `ExitPlanMode` tools turn a session red. `PermissionRequest` fires the moment a permission dialog opens; the notification follows only after an idle delay (about 6 seconds in testing), so without `PermissionRequest` a session blocked on a dialog, such as the dangerous-`rm` check that asks even under `--dangerously-skip-permissions`, showed as working until then. `idle_prompt` (Claude finished and you haven't typed for a while) leaves it at 🟢 finished.
* **Background tasks are inferred from the process table.** A Bash-tool child that outlives the turn counts as a background task, whatever it does. A hook cannot see these tasks, so the plugin counts them itself on each refresh.
* **A subagent you stop by hand fires no `SubagentStop`.** So the plugin stops counting a subagent once it has been silent for 15 minutes while the session runs no shell command, because a live subagent either fires hook events or is running a command. The hook still prunes the entry from the record after an hour.
* **Subagent counts can drift.** Parallel subagents finishing at the same
  instant can race on the read-modify-write of one record and lose a decrement.
  The counter is clamped at zero and resets on the next `SessionStart`; it's a
  hint, not an invariant.
* **Non-local sessions are invisible.** Only sessions on this Mac writing to
  this home directory are tracked.
* **Menu bar counts, not identities.** Two sessions in the same directory look
  identical in the dropdown apart from their tty.

## Testing

```bash
./test.sh
```

A self-contained regression test — no installed hooks or real Claude Code
session required. It points `CLAUDE_AGENT_STATUS_DIR` at a temp directory,
pipes synthetic hook payloads through `./hook.sh`, and asserts the resulting
record with `jq` after each step (main-loop transitions, subagent add/remove,
self-heal, notifications, question dialogs, and a broken `hook-impl.sh` still exiting 0). It also imports the plugin and checks `classify` for every mark. Run it
after any change to `hook.sh`, `hook-impl.sh` or the plugin.

## Files

| Path | Role |
|---|---|
| `hook.sh` | Writes session state records (bash + jq, ~20 ms, always exits 0) |
| `plugins/claude-sessions.5s.py` | SwiftBar plugin, refreshes every 5 s |
| `focus-tab.sh` | Focuses the terminal tab for a given tty (Terminal.app / iTerm2) |
| `install.sh` | Idempotent installer |
| `uninstall.sh` | Removes hooks, plugin link, and status directory |
| `~/.claude/agent-status/*.json` | One record per live session |

## License

MIT — see [LICENSE](LICENSE).

---

Built by Kasmira Stockton. Forked and changed by Megan Holstein.
