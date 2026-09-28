#!/usr/bin/env bash
# ./playbook itself: exit codes survive the logging wrapper, every run is
# logged for `why`, steps that need a keyboard refuse cleanly inside an agent
# (and `why` recognizes that), and test-login's two verdicts. ssh is a stub.
#   ./tests/test-playbook-cli.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
n=0; bad=0
ok()  { n=$((n + 1)); echo "  OK   $*"; }
no()  { n=$((n + 1)); bad=$((bad + 1)); echo "  FAIL $*"; }
export XDG_STATE_HOME="$t/state" HOME="$t/home"
mkdir -p "$HOME" "$t/bin"
cat > "$t/playbook.env" <<ENV
SERVER_HOST=homelab
ADMIN_USER=friend
SSH_PORT=22
SITE_NAME=mysite
DOMAIN=example.org
SITE_PORT=8080
SITE_MARKER="Hello from the cli test"
SITE_DIR=$t/site
ENV
export PLAYBOOK_ENV="$t/playbook.env"
# ssh stub: a key login succeeds; a login without a key succeeds only if
# PASSWORD_WORKS=1 (a server that still takes passwords).
cat > "$t/bin/ssh" <<'STUB'
#!/bin/sh
case " $* " in *PubkeyAuthentication=no*) [ "${PASSWORD_WORKS:-0}" = 1 ] && exit 0; echo "Permission denied (publickey)." >&2; exit 255 ;; esac
exit 0
STUB
chmod +x "$t/bin/ssh"
export PATH="$t/bin:$PATH"
pb="$root/playbook"

out=$("$pb" help 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'server <step>' && ok "help" || no "help (exit $rc)"
out=$("$pb" guide 3); printf '%s\n' "$out" | head -n 1 | grep -q '^## Phase 3:' && ! printf '%s' "$out" | grep -q '^## Phase 4' \
  && ok "guide 3 prints Phase 3 and stops before Phase 4" || no "guide 3"
"$pb" guide 9 >/dev/null 2>&1 && no "guide 9 accepted" || ok "guide 9 refused"
"$pb" launch >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "an unknown command exits 1, through the logging wrapper" || no "unknown command exit $rc"

# A keyboard step, run the way an agent runs it (no terminal): exit 2, the line to paste.
out=$("$pb" server harden </dev/null 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q './playbook server harden' && ok "server harden without a terminal: exit 2 and the line to paste" \
  || { no "server harden without a terminal (exit $rc)"; printf '%s\n' "$out" | tail -5; }
log=$(ls -1t "$XDG_STATE_HOME/homelab-playbook/logs/"*server-harden*.log 2>/dev/null | head -n 1)
[ -n "$log" ] && [ "$(stat -c %a "$log" 2>/dev/null || stat -f %Lp "$log")" = 600 ] && ok "the run was logged, mode 600" || no "no 600 log for the run"
why=$(python3 "$root/scripts/local/diagnose.py" 2>&1)
printf '%s' "$why" | grep -q 'your own terminal' && ok "why reads that log and says it needs your terminal" || { no "why on the log"; printf '%s\n' "$why"; }

# test-login: PASS only when the key works AND a password is refused.
out=$("$pb" server test-login 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'PASS' && ok "test-login passes a key-only server" || no "test-login on a key-only server (exit $rc)"
out=$(PASSWORD_WORKS=1 "$pb" server test-login 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "Don't type yes" && ok "control: test-login FAILS when a password still works" \
  || { no "test-login passed a server that takes passwords"; printf '%s\n' "$out"; }
# The fresh-login proof must not ride a shared connection.
cat > "$t/bin/ssh" <<'STUB'
#!/bin/sh
case " $* " in *ControlPath=none*) exit 0 ;; esac
echo "used a shared connection" >&2; exit 255
STUB
out=$("$pb" server test-login 2>&1)
printf '%s' "$out" | grep -q 'used a shared connection' && no "test-login's logins can reuse a shared connection" || ok "test-login forces a fresh connection (ControlPath=none) for both logins"

echo "cli: $n checks, $bad failed"
[ "$bad" -eq 0 ]
