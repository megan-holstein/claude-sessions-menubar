#!/bin/bash
# claude-sessions-menubar :: regression test
#
# Self-contained: points CLAUDE_AGENT_STATUS_DIR at a throwaway temp dir,
# pipes synthetic Claude Code hook payloads through ./hook.sh, and asserts
# the resulting status record with jq after each step. Never touches
# ~/.claude/agent-status or a real session. Safe to run anytime.
#
# Usage: ./test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hook.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL: %s\n' "$1"
  shift
  for line in "$@"; do
    printf '      %s\n' "$line"
  done
}

assert_eq() {
  # assert_eq <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected [$3] got [$2]"
  fi
}

check_bash_syntax() {
  local desc="$1" file="$2" out
  out="$(bash -n "$file" 2>&1)"
  if [ $? -eq 0 ]; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

check_py_compile() {
  local desc="$1" file="$2" out
  out="$(python3 -m py_compile "$file" 2>&1)"
  if [ $? -eq 0 ]; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

# ============================================================================
# Static checks
# ============================================================================
check_bash_syntax "bash -n hook.sh" "$SCRIPT_DIR/hook.sh"
check_bash_syntax "bash -n hook-impl.sh" "$SCRIPT_DIR/hook-impl.sh"
PLUGIN="$SCRIPT_DIR/plugins/claude-sessions.5s.py"
check_py_compile "python3 -m py_compile plugins/claude-sessions.5s.py" "$PLUGIN"

# ============================================================================
# Hook state-machine scenario
# ============================================================================
TMP_STATUS_DIR="$(mktemp -d)"
BROKEN_DIR=""
cleanup() {
  rm -rf "$TMP_STATUS_DIR" 2>/dev/null
  [ -n "$BROKEN_DIR" ] && rm -rf "$BROKEN_DIR" 2>/dev/null
}
trap cleanup EXIT

export CLAUDE_AGENT_STATUS_DIR="$TMP_STATUS_DIR"

SID="11111111-1111-1111-1111-111111111111"
CWD="/tmp/claude-sessions-menubar-test-proj"
REC="$TMP_STATUS_DIR/$SID.json"

send() {
  # send <json-payload> -- pipes it through hook.sh, returns hook.sh's exit code
  printf '%s' "$1" | "$HOOK"
  return $?
}

field() {
  # field <jq filter> -- reads the current record
  jq -r "$1" "$REC" 2>/dev/null
}

# ---- SessionStart -> idle --------------------------------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"SessionStart","cwd":"'"$CWD"'"}'
rc=$?
assert_eq "hook.sh always exits 0 (normal payload)" "$rc" "0"
assert_eq "SessionStart -> state idle" "$(field .state)" "idle"
assert_eq "SessionStart -> main idle" "$(field .main)" "idle"

# ---- UserPromptSubmit -> working -------------------------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"UserPromptSubmit","cwd":"'"$CWD"'"}'
assert_eq "UserPromptSubmit -> state working" "$(field .state)" "working"
assert_eq "UserPromptSubmit -> main working" "$(field .main)" "working"

# ---- SubagentStart -> subagents --------------------------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStart","agent_id":"agentA","agent_type":"general-purpose","cwd":"'"$CWD"'"}'
assert_eq "SubagentStart -> state subagents" "$(field .state)" "subagents"
assert_eq "SubagentStart -> main left alone (still working)" "$(field .main)" "working"
assert_eq "SubagentStart -> subagents count 1" "$(field .subagents)" "1"
assert_eq "SubagentStart -> agentA recorded with its type" "$(field '.agents.agentA.type')" "general-purpose"

# ---- Stop with a live agent -> state subagents / main done ----------------
send '{"session_id":"'"$SID"'","hook_event_name":"Stop","cwd":"'"$CWD"'"}'
assert_eq "Stop w/ live agent -> state stays subagents" "$(field .state)" "subagents"
assert_eq "Stop w/ live agent -> main becomes done" "$(field .main)" "done"

# ---- PreToolUse with agent_id for an unseen agent --------------------------
# self-heals the agent into `agents`, but must not touch cwd/project.
send '{"session_id":"'"$SID"'","hook_event_name":"PreToolUse","agent_id":"agentB","agent_type":"code-reviewer","tool_name":"Bash","cwd":"/tmp/should-not-apply"}'
assert_eq "PreToolUse unseen agent -> self-healed into agents" "$(field '.agents.agentB.type')" "code-reviewer"
assert_eq "PreToolUse unseen agent -> subagents count 2" "$(field .subagents)" "2"
assert_eq "PreToolUse unseen agent -> cwd NOT overwritten by subagent cwd" "$(field .cwd)" "$CWD"
assert_eq "PreToolUse unseen agent -> project NOT overwritten" "$(field .project)" "$(basename "$CWD")"

# ---- SubagentStop with an unknown id -> no change --------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStop","agent_id":"unknown-agent-id","cwd":"'"$CWD"'"}'
assert_eq "SubagentStop unknown id -> subagents count unchanged" "$(field .subagents)" "2"
assert_eq "SubagentStop unknown id -> agentA still present" "$(field '.agents | has("agentA")')" "true"
assert_eq "SubagentStop unknown id -> agentB still present" "$(field '.agents | has("agentB")')" "true"

# ---- SubagentStop for known ids -> removes them ----------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStop","agent_id":"agentA","cwd":"'"$CWD"'"}'
assert_eq "SubagentStop known id (agentA) -> removed" "$(field '.agents | has("agentA")')" "false"
assert_eq "SubagentStop known id (agentA) -> subagents count 1" "$(field .subagents)" "1"
assert_eq "SubagentStop known id (agentA) -> state still subagents (agentB live)" "$(field .state)" "subagents"

# last live agent goes, main is already "done" -> state should become done
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStop","agent_id":"agentB","cwd":"'"$CWD"'"}'
assert_eq "SubagentStop last agent (agentB) -> subagents count 0" "$(field .subagents)" "0"
assert_eq "SubagentStop last agent, main==done -> state becomes done" "$(field .state)" "done"

# ---- SubagentStop with no agent_id -> removes the oldest -------------------
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStart","agent_id":"agentC","agent_type":"typeC","cwd":"'"$CWD"'"}'
sleep 1.1
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStart","agent_id":"agentD","agent_type":"typeD","cwd":"'"$CWD"'"}'
assert_eq "setup: two agents live before oldest-removal test" "$(field .subagents)" "2"
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStop","cwd":"'"$CWD"'"}'
assert_eq "SubagentStop no agent_id -> removes the oldest (agentC)" "$(field '.agents | has("agentC")')" "false"
assert_eq "SubagentStop no agent_id -> keeps the newer one (agentD)" "$(field '.agents | has("agentD")')" "true"
assert_eq "SubagentStop no agent_id -> subagents count 1" "$(field .subagents)" "1"

# ---- Notification permission_prompt -> needs_input -------------------------
MSG="Claude needs your permission to run: rm -rf /"
send '{"session_id":"'"$SID"'","hook_event_name":"Notification","notification_type":"permission_prompt","message":"'"$MSG"'","cwd":"'"$CWD"'"}'
assert_eq "Notification permission_prompt -> state needs_input" "$(field .state)" "needs_input"
assert_eq "Notification permission_prompt -> main needs_input" "$(field .main)" "needs_input"
assert_eq "Notification permission_prompt -> message stored" "$(field .message)" "$MSG"

# ---- Notification idle_prompt -> no change ---------------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"'"$CWD"'"}'
assert_eq "Notification idle_prompt -> state unchanged (needs_input)" "$(field .state)" "needs_input"
assert_eq "Notification idle_prompt -> main unchanged (needs_input)" "$(field .main)" "needs_input"
assert_eq "Notification idle_prompt -> earlier prompt message preserved" "$(field .message)" "$MSG"
assert_eq "Notification idle_prompt -> notification_type not overwritten" "$(field .notification_type)" "permission_prompt"

# ============================================================================
# Question dialogs: AskUserQuestion and ExitPlanMode fire no Notification
# ============================================================================
SID_Q="22222222-2222-2222-2222-222222222222"
REC_Q="$TMP_STATUS_DIR/$SID_Q.json"
qfield() { jq -r "$1" "$REC_Q" 2>/dev/null; }

send '{"session_id":"'"$SID_Q"'","hook_event_name":"UserPromptSubmit","cwd":"'"$CWD"'"}'
send '{"session_id":"'"$SID_Q"'","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","cwd":"'"$CWD"'"}'
rc=$?
assert_eq "AskUserQuestion PreToolUse -> hook.sh exits 0" "$rc" "0"
assert_eq "AskUserQuestion -> state needs_input" "$(qfield .state)" "needs_input"
assert_eq "AskUserQuestion -> main needs_input" "$(qfield .main)" "needs_input"
assert_eq "AskUserQuestion -> message recorded" "$(qfield .message)" "Claude asked you a question"

# a subagent tool call while the main loop is asking must not clear the question
send '{"session_id":"'"$SID_Q"'","hook_event_name":"PreToolUse","agent_id":"agentQ","agent_type":"general-purpose","tool_name":"Bash","cwd":"'"$CWD"'"}'
assert_eq "subagent PreToolUse during AskUserQuestion -> still needs_input" "$(qfield .state)" "needs_input"
assert_eq "subagent PreToolUse during AskUserQuestion -> message kept" "$(qfield .message)" "Claude asked you a question"
send '{"session_id":"'"$SID_Q"'","hook_event_name":"SubagentStop","agent_id":"agentQ","cwd":"'"$CWD"'"}'

# the next main-context tool call moves it on and clears the message
send '{"session_id":"'"$SID_Q"'","hook_event_name":"PreToolUse","tool_name":"Read","cwd":"'"$CWD"'"}'
assert_eq "next main PreToolUse after AskUserQuestion -> working" "$(qfield .state)" "working"
assert_eq "next main PreToolUse after AskUserQuestion -> message cleared" "$(qfield 'has("message")')" "false"
assert_eq "next main PreToolUse after AskUserQuestion -> notification_type cleared" "$(qfield 'has("notification_type")')" "false"

send '{"session_id":"'"$SID_Q"'","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","cwd":"'"$CWD"'"}'
assert_eq "ExitPlanMode -> state needs_input" "$(qfield .state)" "needs_input"
assert_eq "ExitPlanMode -> message recorded" "$(qfield .message)" "Claude is waiting for you to approve a plan"
send '{"session_id":"'"$SID_Q"'","hook_event_name":"Stop","cwd":"'"$CWD"'"}'
assert_eq "Stop after ExitPlanMode -> main done" "$(qfield .main)" "done"
assert_eq "Stop after ExitPlanMode -> message cleared" "$(qfield 'has("message")')" "false"

send '{"session_id":"'"$SID_Q"'","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","cwd":"'"$CWD"'"}'
send '{"session_id":"'"$SID_Q"'","hook_event_name":"UserPromptSubmit","cwd":"'"$CWD"'"}'
assert_eq "UserPromptSubmit after AskUserQuestion -> working" "$(qfield .state)" "working"

# a subagent's own AskUserQuestion is not the main loop asking
send '{"session_id":"'"$SID_Q"'","hook_event_name":"PreToolUse","agent_id":"agentR","agent_type":"general-purpose","tool_name":"AskUserQuestion","cwd":"'"$CWD"'"}'
assert_eq "subagent AskUserQuestion -> main not moved to needs_input" "$(qfield .main)" "working"

# ============================================================================
# Plugin: classify() maps a record (plus background-task count) to a mark
# ============================================================================
PY_OUT="$(python3 - "$PLUGIN" <<'PYEOF'
import importlib.util, subprocess, sys

spec = importlib.util.spec_from_file_location("claude_sessions_plugin", sys.argv[1])
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)

def rec(main, subs=0, state=None):
    return {"state": state or main, "main": main, "subagents": subs, "agents": {}}

cases = [
    ("needs_input",                       rec("needs_input"),          0, ("needs_you", "🔴", "needs your answer")),
    ("needs_input with subagents and bg", rec("needs_input", 2),       3, ("needs_you", "🔴", "needs your answer")),
    ("done, nothing live",                rec("done"),                 0, ("done", "🟢", "finished")),
    ("working",                           rec("working"),              0, ("busy", "⏳", "working")),
    ("working, 1 subagent",               rec("working", 1),           0, ("busy", "⏳", "working · 1 subagent")),
    ("working, 3 subagents",              rec("working", 3),           0, ("busy", "⏳", "working · 3 subagents")),
    ("working ignores background tasks",  rec("working"),              4, ("busy", "⏳", "working")),
    ("working + subagents ignores bg",    rec("working", 2),           4, ("busy", "⏳", "working · 2 subagents")),
    ("done, 1 subagent",                  rec("done", 1, "subagents"), 0, ("busy", "⏳", "waiting on 1 subagent")),
    ("done, 2 subagents",                 rec("done", 2, "subagents"), 0, ("busy", "⏳", "waiting on 2 subagents")),
    ("done, 1 background task",           rec("done"),                 1, ("busy", "⏳", "waiting on 1 background task")),
    ("done, 3 background tasks",          rec("done"),                 3, ("busy", "⏳", "waiting on 3 background tasks")),
    ("done, subagents and bg",            rec("done", 1, "subagents"), 2, ("busy", "⏳", "waiting on 1 subagent, 2 background tasks")),
    ("idle, nothing live",                rec("idle"),                 0, ("new", "⚪", "new, nothing asked yet")),
    ("idle, 1 background task",           rec("idle"),                 1, ("busy", "⏳", "waiting on 1 background task")),
    ("idle, 1 subagent",                  rec("idle", 1, "subagents"), 0, ("busy", "⏳", "waiting on 1 subagent")),
]

# a subagent stopped by hand fires no SubagentStop: silent past QUIET_AFTER with
# no shell running, it no longer counts; with a shell running, it still does
bad = 0
NOW = 1_000_000.0
def with_agents(main, *seen_ago):
    r = rec(main, len(seen_ago), "subagents")
    r["agents"] = {"a%d" % i: {"type": "general-purpose", "since": NOW - 9999, "seen": NOW - ago}
                   for i, ago in enumerate(seen_ago)}
    return r
for name, r, bg, want in [
    ("done, stale subagent, no shell",       with_agents("done", 3600 - 60), 0, ("done", "🟢", "finished")),
    ("done, stale subagent, shell running",  with_agents("done", 3600 - 60), 1, ("busy", "⏳", "waiting on 1 subagent, 1 background task")),
    ("done, one fresh one stale subagent",   with_agents("done", 30, 3000),  0, ("busy", "⏳", "waiting on 1 subagent")),
    ("working, stale subagent, no shell",    with_agents("working", 3000),   0, ("busy", "⏳", "working")),
]:
    got = plugin.classify(r, bg, now=NOW)
    if got == want:
        print("PASS: classify: %s" % name)
    else:
        bad += 1
        print("FAIL: classify: %s" % name)
        print("      expected %r got %r" % (want, got))
for name, r, bg, want in cases:
    got = plugin.classify(r, bg)
    if got == want:
        print("PASS: classify: %s" % name)
    else:
        bad += 1
        print("FAIL: classify: %s" % name)
        print("      expected %r got %r" % (want, got))

real_run = subprocess.run

# a failing ps must give a count of 0, never a crash
def boom(*a, **k):
    raise OSError("ps unavailable")
subprocess.run = boom
try:
    ok = plugin.background_counts() == {}
finally:
    subprocess.run = real_run
print(("PASS" if ok else "FAIL") + ": background_counts returns {} when ps fails")
bad += 0 if ok else 1

class Fake:
    stdout = (
        " 100 /bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1-a.sh && cmd\n"
        " 100 /bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1-a.sh && other\n"
        " 200 /bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-2-b.sh && cmd\n"
        " 100 /usr/bin/python3 something-else\n"
        " garbage\n"
    )
subprocess.run = lambda *a, **k: Fake()
try:
    counts = plugin.background_counts()
finally:
    subprocess.run = real_run
ok = counts == {100: 2, 200: 1}
print(("PASS" if ok else "FAIL") + ": background_counts counts snapshot children per parent pid")
if not ok:
    print("      got %r" % (counts,))
bad += 0 if ok else 1
sys.exit(1 if bad else 0)
PYEOF
)"
PY_RC=$?
while IFS= read -r line; do
  case "$line" in
    PASS:*) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL:*) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
  esac
  printf '%s\n' "$line"
done <<< "$PY_OUT"
assert_eq "plugin test script exits 0" "$PY_RC" "0"

# ============================================================================
# Launcher safety: a broken hook-impl.sh must still exit 0
# ============================================================================
BROKEN_DIR="$(mktemp -d)"
cp "$SCRIPT_DIR/hook.sh" "$BROKEN_DIR/hook.sh"
cat > "$BROKEN_DIR/hook-impl.sh" <<'EOF'
#!/bin/bash
fi   # deliberately invalid syntax -- bash exits 2 on this
EOF
chmod +x "$BROKEN_DIR/hook.sh" "$BROKEN_DIR/hook-impl.sh"
printf '%s' '{"session_id":"'"$SID"'","hook_event_name":"SessionStart"}' | "$BROKEN_DIR/hook.sh"
rc=$?
assert_eq "broken hook-impl.sh -> launcher still exits 0" "$rc" "0"

# ============================================================================
# Summary
# ============================================================================
echo "----------------------------------------"
echo "$PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
