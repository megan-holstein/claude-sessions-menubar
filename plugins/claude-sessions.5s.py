#!/usr/bin/env python3
# <xbar.title>Claude Sessions</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>Kasmira</xbar.author>
# <xbar.desc>Shows every running Claude Code session and what you have to do next, and focuses its Terminal tab on click.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
#
# Reads the records written by ~/.claude/claude-sessions-menubar/hook.sh.
# Run with `--clear` to prune dead/corrupt records without printing a menu.

import glob
import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
STATUS_DIR = os.environ.get(
    "CLAUDE_AGENT_STATUS_DIR", os.path.join(HOME, ".claude", "agent-status")
)

# Resolve the sibling focus script. SwiftBar resolves symlinks in the plugin
# path, so fall back to the canonical install location.
_here = os.path.dirname(os.path.abspath(os.environ.get("SWIFTBAR_PLUGIN_PATH", __file__)))
FOCUS = os.path.join(os.path.dirname(_here), "focus-tab.sh")
if not os.path.isfile(FOCUS):
    FOCUS = os.path.join(HOME, ".claude", "claude-sessions-menubar", "focus-tab.sh")

# Marks describe what YOU have to do, loudest first. The order is both the
# menu-bar title order and the dropdown order.
MARK_ORDER = ["needs_you", "done", "working", "waiting", "new"]
MARK_ICON = {
    "needs_you": "🔴",
    "done": "🟢",
    "working": "🔄",
    "waiting": "⏳",
    "new": "⚪",
}
LEGEND = [
    ("needs_you", "act now — a prompt or question is blocking it"),
    ("done", "your turn — it finished"),
    ("working", "working"),
    ("waiting", "waiting on its own subagents or background tasks"),
    ("new", "opened, nothing asked yet"),
]

# Claude Code's Bash tool runs each command as a direct child of the `claude`
# process, with a command line that contains this path.
SHELL_SNAPSHOT = "/.claude/shell-snapshots/snapshot-"

QUIET_AFTER = 15 * 60  # seconds of silence after which a subagent with no shell children counts as gone


def live_pids():
    """One `ps` call -> {pid: comm}. Cheaper and more correct than kill(0)
    alone, which can't tell a recycled pid from the original claude."""
    try:
        out = subprocess.run(
            ["/bin/ps", "-Ao", "pid=,comm="],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return None
    procs = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        pid, _, comm = line.partition(" ")
        try:
            procs[int(pid)] = comm.strip()
        except ValueError:
            pass
    return procs


def background_counts():
    """One `ps` call -> {claude pid: number of Bash-tool children}.

    A Bash-tool child that is still alive after the turn ended is a
    run_in_background task or a Monitor watcher. Any failure returns {}."""
    try:
        out = subprocess.run(
            ["/bin/ps", "-Ao", "ppid=,args="],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return {}
    counts = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        ppid, _, args = line.partition(" ")
        if SHELL_SNAPSHOT not in args:
            continue
        try:
            ppid = int(ppid)
        except ValueError:
            continue
        counts[ppid] = counts.get(ppid, 0) + 1
    return counts


def _count(value):
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError):
        return 0


def _plural(n, noun):
    return "%d %s%s" % (n, noun, "" if n == 1 else "s")


def _live_subagents(rec, bg, now):
    """Subagents still counted as live. Claude Code sends no SubagentStop for
    a subagent the user stops by hand, so its entry would otherwise linger
    until the hook's one-hour expiry. An entry silent for QUIET_AFTER while
    the session holds no shell children is counted as gone: a live subagent
    either fires hook events or is running a shell command."""
    agents = rec.get("agents")
    if not isinstance(agents, dict) or not agents:
        return _count(rec.get("subagents"))
    live = 0
    for ag in agents.values():
        try:
            quiet = (now - float((ag or {}).get("seen"))) > QUIET_AFTER
        except (TypeError, ValueError, AttributeError):
            quiet = False
        if not (quiet and not bg):
            live += 1
    return live


def classify(rec, bg_count=0, now=None):
    """Decide the mark for one session record.

    Returns (mark_key, icon, text). `bg_count` is the number of background
    tasks the session's `claude` process holds; it changes the mark only when
    the main loop is done or idle, because a foreground Bash call is normal
    while the main loop works."""
    state = rec.get("state")
    main = rec.get("main") or state
    bg = _count(bg_count)
    n_sub = _live_subagents(rec, bg, time.time() if now is None else now)

    if main == "needs_input" or state == "needs_input":
        key, text = "needs_you", "needs your answer"
    elif main in ("done", "idle"):
        if n_sub or bg:
            waits = []
            if n_sub:
                waits.append(_plural(n_sub, "subagent"))
            if bg:
                waits.append(_plural(bg, "background task"))
            key, text = "waiting", "waiting on " + ", ".join(waits)
        elif main == "done":
            key, text = "done", "finished"
        else:
            key, text = "new", "new, nothing asked yet"
    else:
        key = "working"
        text = "working · %s" % _plural(n_sub, "subagent") if n_sub else "working"
    return key, MARK_ICON[key], text


def is_alive(pid, procs):
    if not pid:
        return False
    if procs is not None:
        comm = procs.get(pid)
        return comm is not None and os.path.basename(comm) == "claude"
    try:                       # fallback if `ps` was unavailable
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False


def load(prune_only=False):
    """Return live session records; delete records for dead or corrupt ones."""
    procs = live_pids()
    sessions = []
    try:
        names = sorted(os.listdir(STATUS_DIR))
    except FileNotFoundError:
        return []
    for name in names:
        if not name.endswith(".json") or name.endswith(".tmp"):
            continue
        path = os.path.join(STATUS_DIR, name)
        try:
            with open(path) as fh:
                rec = json.load(fh)
            if not isinstance(rec, dict):
                raise ValueError("not an object")
        except Exception:
            if prune_only:
                _unlink(path)
            continue
        if not is_alive(rec.get("pid"), procs):
            _unlink(path)
            continue
        sessions.append(rec)
    return sessions


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def elapsed(since):
    try:
        secs = int(time.time() - float(since))
    except (TypeError, ValueError):
        return "?"
    if secs < 0:
        secs = 0
    if secs < 60:
        return "%ds" % secs
    if secs < 3600:
        return "%dm" % (secs // 60)
    hours, mins = divmod(secs // 60, 60)
    if hours < 24:
        return "%dh%02dm" % (hours, mins)
    days, hours = divmod(hours, 24)
    return "%dd%02dh" % (days, hours)


def clean(text):
    """`|` separates a SwiftBar item's title from its parameters, and a leading
    `--` would make the line a submenu entry. Neither may leak in from a path."""
    text = str(text).replace("|", "│").replace("\n", " ").strip()
    while text.startswith("--"):
        text = text[2:]
    return text or "?"


def _since_key(value):
    """Sort key for `state_since`; a missing or unparseable value sorts first."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _registry_name(pid, session_id):
    """A user-set /rename name from ~/.claude/sessions/<pid>.json, if any.

    `nameSource` is "derived" for Claude Code's own auto-generated name;
    anything else (including a missing field) is treated as user-set, per
    spec. Only trusted when the registry's own sessionId still matches."""
    if not pid or not session_id:
        return None
    path = os.path.join(HOME, ".claude", "sessions", "%s.json" % pid)
    try:
        with open(path) as fh:
            reg = json.load(fh)
        if not isinstance(reg, dict):
            return None
        if reg.get("sessionId") != session_id:
            return None
        if reg.get("nameSource") == "derived":
            return None
        name = reg.get("name")
        return str(name) if name else None
    except Exception:
        return None


def _ai_titles_in(lines):
    """Last aiTitle among an iterable of raw jsonl lines, or None."""
    marker = b'"type":"ai-title"'
    title = None
    for line in lines:
        if marker not in line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if isinstance(rec, dict) and rec.get("type") == "ai-title":
            t = rec.get("aiTitle")
            if t:
                title = str(t)
    return title


def _last_ai_title(path):
    """The most recent `ai-title` line's aiTitle. Scans only the tail of the
    file (cheap, fine for a 5s-refresh plugin); falls back to a full,
    line-filtered pass only when the tail didn't contain one at all."""
    TAIL = 256 * 1024
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > TAIL:
                fh.seek(size - TAIL)
                fh.readline()  # drop the partial line left by the seek
            title = _ai_titles_in(fh)
        if title is not None or size <= TAIL:
            return title
        with open(path, "rb") as fh:
            return _ai_titles_in(fh)
    except Exception:
        return None


def _transcript_title(session_id):
    if not session_id:
        return None
    try:
        matches = glob.glob(os.path.join(
            HOME, ".claude", "projects", "*", "%s.jsonl" % session_id))
        if not matches:
            return None
        path = max(matches, key=lambda p: os.path.getmtime(p))
        return _last_ai_title(path)
    except Exception:
        return None


def truncate(text, limit=36):
    text = str(text)
    if len(text) <= limit:
        return text
    if limit <= 1:
        return text[:limit]
    return text[:limit - 1].rstrip() + "…"


def session_label(rec):
    """Custom /rename name > transcript auto title > `project` (cwd basename)."""
    try:
        name = _registry_name(rec.get("pid"), rec.get("session_id"))
        if name:
            return truncate(name)
    except Exception:
        pass
    try:
        title = _transcript_title(rec.get("session_id"))
        if title:
            return truncate(title)
    except Exception:
        pass
    return truncate(rec.get("project") or "?")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--clear":
        load(prune_only=True)
        return

    sessions = load()
    bg = background_counts()

    rows = []
    for rec in sessions:
        try:
            pid = int(rec.get("pid") or 0)
        except (TypeError, ValueError):
            pid = 0
        n_bg = bg.get(pid, 0)
        rows.append((rec, n_bg) + classify(rec, n_bg))

    # ---- menu bar title ---------------------------------------------------
    counts = {}
    for row in rows:
        counts[row[2]] = counts.get(row[2], 0) + 1
    if not rows:
        print("Claude: none")
    else:
        print(" ".join("%s%d" % (MARK_ICON[k], counts[k])
                       for k in MARK_ORDER if counts.get(k)))

    print("---")

    if not rows:
        print("No Claude Code sessions running | color=#888888")
    else:
        rows.sort(key=lambda r: (MARK_ORDER.index(r[2]), _since_key(r[0].get("state_since"))))
        for s, _n_bg, _mark, icon, text in rows:
            label = clean(session_label(s))
            tty = str(s.get("tty") or "")
            line = "%s %s  %s  %s" % (icon, label, text, elapsed(s.get("state_since")))
            params = ["symbolize=false"]
            if tty:
                term_prog = clean(s.get("terminal") or "Apple_Terminal")
                params += ["bash=%s" % FOCUS, "param1=%s" % tty,
                           "param2=%s" % term_prog,
                           "terminal=false", "refresh=false"]
            print("%s | %s" % (line, " ".join(params)))

    print("---")
    print("Open status folder | bash=/usr/bin/open param1=%s terminal=false refresh=false"
          % STATUS_DIR)
    plugin = os.environ.get("SWIFTBAR_PLUGIN_PATH", os.path.abspath(__file__))
    print("Clear stale | bash=%s param1=--clear terminal=false refresh=true" % plugin)

    print("---")
    for key, meaning in LEGEND:
        print("%s %s | symbolize=false color=#888888" % (MARK_ICON[key], meaning))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:              # never leave a bare ⚠️ in the menu bar
        print("⚠️ Claude")
        print("---")
        print("plugin error: %s | color=red" % str(exc).replace("|", "/"))
