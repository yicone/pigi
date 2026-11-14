#!/bin/sh
# Offline self-test for pigi_forced_command.sh (ACM-963 rework, ACM-965 items
# 1-4 and the offline-checkable part of 6).
#
# Method: render a throwaway copy whose four pinned literals are replaced with
# synthetic values (the installed production file is never modified), drive it
# with a stub interpreter under a temporary HOME and hostile environment.
# Never opens agent.sock, the App, mail.db, keychains, or real audit ledgers.
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
: > "$SCRIPT_PATH"
ACCOUNT='billing-test@example.invalid'
LOGDIR="$TMP/led"
LOG="$LOGDIR/forced-command.log"
mkdir -m 700 "$LOGDIR"

# Render a test copy: identical logic, synthetic pinned constants only.
render() { # render <log-path> -> stdout: path of rendered script
    out="$TMP/fc-$1.sh"
    sed -e "s|^readonly PIGI_MCP_PYTHON=.*|readonly PIGI_MCP_PYTHON='$STUB'|" \
        -e "s|^readonly PIGI_MCP_SCRIPT=.*|readonly PIGI_MCP_SCRIPT='$SCRIPT_PATH'|" \
        -e "s|^readonly PIGI_MCP_ACCOUNT=.*|readonly PIGI_MCP_ACCOUNT='$ACCOUNT'|" \
        -e "s|^readonly PIGI_FC_LOG=.*|readonly PIGI_FC_LOG='$2'|" \
        "$FC" > "$out"
    chmod 700 "$out"
    grep -q "readonly PIGI_MCP_ACCOUNT='$ACCOUNT'" "$out" || {
        echo "render failed: pinned literal not substituted" >&2; exit 2; }
    printf %s "$out"
}

TESTFC="$(render main "$LOG")"
EXPECTED="$STUB -B $SCRIPT_PATH --account $ACCOUNT"
sh -n "$FC" && sh -n "$TESTFC" || { echo 'syntax check failed' >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

run() { # run <fc> <original|'__UNSET__'> [extra env via ENVX] -> OUT ERR RC
    OUT="$TMP/out"; ERR="$TMP/err"
    if [ "$2" = '__UNSET__' ]; then
        env -u SSH_ORIGINAL_COMMAND ${ENVX:-} SSH_CLIENT='10.9.9.9 5000 22' \
            sh "$1" >"$OUT" 2>"$ERR" && RC=0 || RC=$?
    else
        env ${ENVX:-} SSH_ORIGINAL_COMMAND="$2" SSH_CLIENT='10.9.9.9 5000 22' \
            sh "$1" >"$OUT" 2>"$ERR" && RC=0 || RC=$?
    fi
}
linefmt='^[0-9-]+T[0-9:]+Z	[A-Za-z0-9.:]+	(allow|deny)	[a-z-]+	[0-9]+	[0-9a-f-]+$'

# -- 1. Exact pinned invocation runs the fixed pipeline ---------------------
run "$TESTFC" "$EXPECTED"
[ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$OUT" \
    && grep -q -- "<-B> <$SCRIPT_PATH> <--account> <$ACCOUNT>" "$OUT"
check 'allow: exact pinned command execs fixed pipeline' $?
grep -Eq "$linefmt" "$LOG" && grep -q '	allow	exact	' "$LOG"
check 'ledger: allow event in controlled format' $?

# -- 2/3/4. Denials ----------------------------------------------------------
run "$TESTFC" 'rm -rf /'
{ [ "$RC" -eq 1 ] && grep -q 'not permitted' "$ERR" && ! grep -q 'STUB-EXECUTED' "$OUT"; }
check 'deny: arbitrary command rejected, stub not run' $?

run "$TESTFC" "$STUB -B $SCRIPT_PATH --account other@example.invalid"
{ [ "$RC" -eq 1 ] && ! grep -q 'STUB-EXECUTED' "$OUT"; }
check 'deny: different account rejected' $?

run "$TESTFC" '__UNSET__'
{ [ "$RC" -eq 1 ] && ! grep -q 'STUB-EXECUTED' "$OUT" && grep -q '	deny	empty	' "$LOG"; }
check 'deny: empty command rejected as deny/empty' $?

# -- 5. Metacharacters are inert data, never reach a shell -------------------
run "$TESTFC" "$EXPECTED; touch $TMP/pwned"
{ [ "$RC" -eq 1 ] && [ ! -e "$TMP/pwned" ]; }
check 'deny: injected metacharacters never reach a shell' $?

# -- 6. Environment cannot change authorization (ACM-965 item 4) -------------
ENVX="PIGI_MCP_ACCOUNT=other@example.invalid PIGI_MCP_PYTHON=/bin/false PIGI_MCP_SCRIPT=/bin/false PIGI_FC_LOG=/tmp/evil PYTHONPATH=/evil PYTHONHOME=/evil IFS=x BASH_ENV=/evil ENV=/evil"
run "$TESTFC" "$STUB -B $SCRIPT_PATH --account other@example.invalid"
unset ENVX
{ [ "$RC" -eq 1 ] && ! grep -q 'STUB-EXECUTED' "$OUT" && [ ! -e /tmp/evil ]; }
check 'env-inject: hostile env cannot widen the pinned scope' $?

ENVX="PIGI_MCP_ACCOUNT=other@example.invalid PIGI_MCP_PYTHON=/bin/false PIGI_FC_LOG=/tmp/evil PYTHONPATH=/evil"
run "$TESTFC" "$EXPECTED"
unset ENVX
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$OUT" && [ ! -e /tmp/evil ]; }
check 'env-inject: pinned literals still win over injected env' $?

# -- 7. Secrets/newlines/control chars never enter the ledger (item 2) -------
before=$(wc -l < "$LOG")
run "$TESTFC" 'DENIED SECRET_SENTINEL
FORGED-LEDGER-ROW	allow	exact	1	x'
{ [ "$RC" -eq 1 ] \
    && ! grep -qF 'SECRET_SENTINEL' "$LOG" && ! grep -qF 'FORGED-LEDGER-ROW' "$LOG" \
    && [ "$(wc -l < "$LOG")" -eq $((before + 1)) ] \
    && tail -1 "$LOG" | grep -Eq "$linefmt"; }
check 'ledger: secret+newline payload stays out, one clean record' $?

# -- 8. Oversized request yields one bounded record --------------------------
big=$(printf 'A%.0s' $(seq 1 20480))A
before=$(wc -l < "$LOG")
run "$TESTFC" "$big"
{ [ "$RC" -eq 1 ] && [ "$(wc -l < "$LOG")" -eq $((before + 1)) ] \
    && tail -1 "$LOG" | grep -q "	$((20481))	"; }
check 'ledger: oversized request logged as one line with length' $?

# -- 9. Fail-closed ledger validation (ACM-965 item 1) -----------------------
refused() { # refused <name> <log-path>
    fc="$(render "$1" "$2")"
    run "$fc" "$EXPECTED"
    [ "$RC" -eq 1 ] && ! grep -q 'STUB-EXECUTED' "$OUT" && grep -q 'unavailable' "$ERR"
}

# 9a. A parent component is a regular file: mkdir and append both fail.
notdir="$TMP/not-a-directory"; : > "$notdir"
refused notdir "$notdir/log"
check 'fail-closed: log parent is a file -> refused, stub not run' $?

# 9b. Existing directory with permissive mode is refused, not repaired.
widedir="$TMP/wide"; mkdir -m 755 "$widedir"
refused widedir "$widedir/forced-command.log"
check 'fail-closed: 0755 log directory -> refused' $?
[ "$(stat -f %Lp "$widedir")" = '755' ]
check 'fail-closed: refused dir keeps original 0755 mode' $?

# 9c. Existing 0644 log is refused, never appended or chmod'ed.
widelogdir="$TMP/widelog"; mkdir -m 700 "$widelogdir"
printf 'synthetic\n' > "$widelogdir/forced-command.log"
chmod 644 "$widelogdir/forced-command.log"
refused widelog "$widelogdir/forced-command.log"
{ [ "$(stat -f %Lp "$widelogdir/forced-command.log")" = '644' ] \
    && [ "$(wc -l < "$widelogdir/forced-command.log")" -eq 1 ]; }
check 'fail-closed: 0644 log refused, mode+content unchanged' $?

# 9d. Symlinked log is refused and its target is never appended.
target="$TMP/target"; printf 'synthetic\n' > "$target"; chmod 600 "$target"
alias_dir="$TMP/aliasd"; mkdir -m 700 "$alias_dir"
ln -s "$target" "$alias_dir/forced-command.log"
refused symlink "$alias_dir/forced-command.log"
[ "$(wc -l < "$target")" -eq 1 ]
check 'fail-closed: symlinked log refused, target untouched' $?

# 9e. Dangling symlink is also refused.
ln -s "$TMP/nonexistent" "$alias_dir/dangling.log"
refused dangling "$alias_dir/dangling.log"
check 'fail-closed: dangling symlink refused' $?

# 9f. Log path that is a directory is refused.
logisdir="$TMP/logisdir"; mkdir -m 700 "$logisdir"; mkdir "$logisdir/forced-command.log"
refused logisdir "$logisdir/forced-command.log"
check 'fail-closed: directory at log path refused' $?

# 9g. Hard-linked ledger (nlink>1) is refused.
hldir="$TMP/hardlink"; mkdir -m 700 "$hldir"
printf 'synthetic\n' > "$hldir/forced-command.log"; chmod 600 "$hldir/forced-command.log"
ln "$hldir/forced-command.log" "$hldir/other-name"
refused hardlink "$hldir/forced-command.log"
check 'fail-closed: hard-linked log refused' $?

# 9h. Fresh dir+log are auto-created with strict modes, then serve.
freshlog="$TMP/freshdir/forced-command.log"
freshfc="$(render fresh "$freshlog")"
run "$freshfc" "$EXPECTED"
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$OUT" \
    && [ "$(stat -f %Lp "$TMP/freshdir")" = '700' ] \
    && [ "$(stat -f %Lp "$freshlog")" = '600' ]; }
check 'allow: fresh ledger auto-created 0700/0600' $?

# -- 10. authorized_keys launch form (ACM-965 item 3) ------------------------
# sshd parses command="VALUE" (\" unescapes to literal ") then runs `sh -c VALUE`.
akvalue() { printf %s "$1" | sed 's/\\"/"/g'; }

# 10a. Space-free installed path: `sh -c` receives the bare path and runs it.
val="$(akvalue "$TESTFC")"
SSH_ORIGINAL_COMMAND="$EXPECTED" SSH_CLIENT='10.9.9.9 5000 22' \
    /bin/sh -c "$val" >"$TMP/out" 2>"$TMP/err" && RC=0 || RC=$?
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$TMP/out"; }
check 'launch: space-free authorized_keys path executes via sh -c' $?

# 10b. Escaped-quote form survives a spaced path (the corrected quoting rule).
spaced="$TMP/Application Support"; mkdir -p "$spaced"
spacedfc="$spaced/pigi_forced_command.sh"
cp "$TESTFC" "$spacedfc"; chmod 700 "$spacedfc"
stored="\"$spacedfc\""                       # what authorized_keys stores
val="$(akvalue "$stored")"                   # what `sh -c` receives
SSH_ORIGINAL_COMMAND="$EXPECTED" SSH_CLIENT='10.9.9.9 5000 22' \
    /bin/sh -c "$val" >"$TMP/out" 2>"$TMP/err" && RC=0 || RC=$?
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$TMP/out"; }
check 'launch: escaped-quote spaced path executes via sh -c' $?

# 10c. The documented authorized_keys entry itself, end to end.
ak_line="from=\"192.0.2.10\",restrict,command=\"\\\"$spacedfc\\\"\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeSyntheticKeyMaterialForTestingOnlyx"
cmdval=$(printf %s "$ak_line" | sed -n -E 's/.*command="((\\.|[^"])*)" ssh-.*/\1/p' | sed 's/\\"/"/g')
SSH_ORIGINAL_COMMAND="$EXPECTED" SSH_CLIENT='10.9.9.9 5000 22' \
    /bin/sh -c "$cmdval" >"$TMP/out" 2>"$TMP/err" && RC=0 || RC=$?
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$TMP/out"; }
check 'launch: full authorized_keys line parses and runs spaced path' $?

# -- 11. ssh client config / known_hosts consistency (item 6, offline) -------
sshcfg="$TMP/ssh_config"
cat > "$sshcfg" <<EOF
Host tr-mini-m4-pigi
    HostName 192.0.2.10
    User tr
    IdentityFile $TMP/pigi_billing_ed25519
    IdentitiesOnly yes
    HostKeyAlias tr-mini-m4-pigi
EOF
resolved=$(ssh -G -F "$sshcfg" tr-mini-m4-pigi 2>/dev/null)
printf %s "$resolved" | grep -q '^hostname 192\.0\.2\.10$' \
    && printf %s "$resolved" | grep -q '^hostkeyalias tr-mini-m4-pigi$' \
    && printf %s "$resolved" | grep -q '^identitiesonly yes$' \
    && printf %s "$resolved" | grep -q "identityfile $TMP/pigi_billing_ed25519"
check 'ssh-config: alias resolves to pinned host/keyalias/identity' $?

kh="$TMP/known_hosts"
printf 'tr-mini-m4-pigi ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeSyntheticKeyMaterialForTestingOnlyx\n' > "$kh"
ssh-keygen -F tr-mini-m4-pigi -f "$kh" | grep -q 'tr-mini-m4-pigi'
check 'known_hosts: entry found under the same alias ssh uses' $?
{ printf %s "$resolved" | grep '^hostkeyalias ' | awk '{print $2}' \
    | grep -qx 'tr-mini-m4-pigi' && grep -q '^tr-mini-m4-pigi ' "$kh"; }
check 'known_hosts: lookup name matches resolved HostKeyAlias' $?

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
