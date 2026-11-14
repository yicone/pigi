#!/bin/sh
# Offline self-test for pigi_forced_command.sh (ACM-963).
# Substitutes a stub interpreter via the PIGI_MCP_* test overrides; never opens
# agent.sock, the App, mail.db, or any real account. Run: sh test_pigi_forced_command.sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
FC="$ROOT/pigi_forced_command.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pigi-fc-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

STUB="$TMP/stub-python3"
cat > "$STUB" <<'EOF'
#!/bin/sh
printf 'STUB-EXECUTED'
for a in "$@"; do printf ' <%s>' "$a"; done
printf '\n'
EOF
chmod 700 "$STUB"

SCRIPT_PATH="$TMP/pigi_mcp.py"
ACCOUNT='billing-test@example.invalid'
LOG="$TMP/forced-command.log"

export PIGI_MCP_PYTHON="$STUB" PIGI_MCP_SCRIPT="$SCRIPT_PATH"
export PIGI_MCP_ACCOUNT="$ACCOUNT" PIGI_FC_LOG="$LOG"
EXPECTED="$STUB -B $SCRIPT_PATH --account $ACCOUNT"

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check <name> <condition-exit-status>
    if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

run() { # run <ssh_original_command-or-EMPTY_SENTINEL> -> sets OUT/ERR/RC
    OUT="$TMP/out"; ERR="$TMP/err"
    if [ "$1" = "__UNSET__" ]; then
        env -u SSH_ORIGINAL_COMMAND SSH_CLIENT='10.9.9.9 5000 22' sh "$FC" >"$OUT" 2>"$ERR" && RC=0 || RC=$?
    else
        SSH_ORIGINAL_COMMAND="$1" SSH_CLIENT='10.9.9.9 5000 22' sh "$FC" >"$OUT" 2>"$ERR" && RC=0 || RC=$?
    fi
}

# 1. Exact pinned invocation runs the fixed pipeline.
run "$EXPECTED"
[ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$OUT" \
    && grep -q -- "<-B> <$SCRIPT_PATH> <--account> <$ACCOUNT>" "$OUT"
check 'allow: exact pinned command execs fixed pipeline' $?

# 2. Arbitrary command is rejected and never executed.
run 'rm -rf /'
{ [ "$RC" -eq 1 ] && grep -q 'not permitted' "$ERR" && ! grep -q 'STUB-EXECUTED' "$OUT"; }
check 'deny: arbitrary command rejected, stub not run' $?

# 3. Wrong account scope is rejected.
run "$STUB -B $SCRIPT_PATH --account other@example.invalid"
{ [ "$RC" -eq 1 ] && ! grep -q 'STUB-EXECUTED' "$OUT"; }
check 'deny: different account rejected' $?

# 4. Missing SSH_ORIGINAL_COMMAND is rejected.
run '__UNSET__'
{ [ "$RC" -eq 1 ] && ! grep -q 'STUB-EXECUTED' "$OUT"; }
check 'deny: empty command rejected' $?

# 5. Shell metacharacters in the request are inert data, not executed.
run "$EXPECTED; touch $TMP/pwned"
{ [ "$RC" -eq 1 ] && [ ! -e "$TMP/pwned" ]; }
check 'deny: injected metacharacters never reach a shell' $?

# 6. Every attempt (allowed and denied) is appended to the ledger.
lines=$(wc -l < "$LOG" | tr -d ' ')
{ [ "$lines" -eq 5 ] && grep -q '10\.9\.9\.9' "$LOG" \
    && grep -qF "$EXPECTED" "$LOG" && grep -q 'rm -rf /' "$LOG"; }
check 'audit: all five attempts logged with peer and request' $?

# 7. Log and its parent carry private permissions.
perm=$(stat -f %Lp "$LOG")
{ [ "$perm" = '600' ]; }
check 'audit: ledger file mode 600' $?

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
