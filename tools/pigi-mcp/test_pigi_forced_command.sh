#!/bin/sh
# Offline self-test for pigi_forced_command.sh (ACM-963 rework, ACM-965/966).
#
# Method: render a throwaway copy whose five pinned literals are replaced with
# synthetic values (the installed production file is never modified), drive it
# with stub interpreters under a resolved temporary scratch dir and hostile
# environment. Never opens agent.sock, the App, mail.db, keychains, or real
# audit ledgers; never touches real HOME data.
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
FC="$ROOT/pigi_forced_command.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pigi-fc-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"   # physical path: ancestor checks reject /var symlinks
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
THOME="$TMP/fc-home"; mkdir -m 700 "$THOME"
LOGDIR="$TMP/led"
LOG="$LOGDIR/forced-command.log"
mkdir -m 700 "$LOGDIR"

# Render a test copy: identical logic, synthetic pinned constants only.
render() { # render <name> <log-path> [python] [script] [home]
    out="$TMP/fc-$1.sh"
    py=${3:-$STUB}; sc=${4:-$SCRIPT_PATH}; hm=${5:-$THOME}
    sed -e "s|^readonly PIGI_FC_HOME=.*|readonly PIGI_FC_HOME='$hm'|" \
        -e "s|^readonly PIGI_MCP_PYTHON=.*|readonly PIGI_MCP_PYTHON='$py'|" \
        -e "s|^readonly PIGI_MCP_SCRIPT=.*|readonly PIGI_MCP_SCRIPT='$sc'|" \
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

run() { # run <fc> <original|'__UNSET__'> -> OUT ERR RC ; ENVX may add hostile env
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
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$OUT" \
    && grep -q -- "<-B> <-E> <-S> <-X> <utf8> <$SCRIPT_PATH> <--account> <$ACCOUNT>" "$OUT"; }
check 'allow: exact pinned command execs hardened pipeline' $?
{ grep -Eq "$linefmt" "$LOG" && grep -q '	allow	exact	' "$LOG"; }
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
EVIL="$TMP/evil"
ENVX="PIGI_MCP_ACCOUNT=other@example.invalid PIGI_MCP_PYTHON=/bin/false PIGI_MCP_SCRIPT=/bin/false PIGI_FC_LOG=$EVIL PIGI_FC_HOME=$EVIL PYTHONPATH=$EVIL PYTHONHOME=$EVIL IFS=x BASH_ENV=$EVIL ENV=$EVIL"
run "$TESTFC" "$STUB -B $SCRIPT_PATH --account other@example.invalid"
unset ENVX
{ [ "$RC" -eq 1 ] && ! grep -q 'STUB-EXECUTED' "$OUT" && [ ! -e "$EVIL" ]; }
check 'env-inject: hostile env cannot widen the pinned scope' $?

ENVX="PIGI_MCP_ACCOUNT=other@example.invalid PIGI_MCP_PYTHON=/bin/false PIGI_FC_LOG=$EVIL PYTHONPATH=$EVIL"
run "$TESTFC" "$EXPECTED"
unset ENVX
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$OUT" && [ ! -e "$EVIL" ]; }
check 'env-inject: pinned literals still win over injected env' $?

# -- 7. Secrets/newlines/control chars never enter the ledger -----------------
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
    && tail -1 "$LOG" | grep -q "	20481	"; }
check 'ledger: oversized request logged as one line with length' $?

# -- 9. Fail-closed ledger validation ----------------------------------------
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

# -- 10. Ancestor-path validation (ACM-966 item 1) -----------------------------
# 10a. World/group-writable non-sticky ancestor is refused.
wanc="$TMP/writable-ancestor"; mkdir -m 777 "$wanc"
mkdir -m 700 "$wanc/leaf"
refused wanc "$wanc/leaf/forced-command.log"
check 'ancestors: non-sticky 0777 ancestor refused' $?

# 10b. Sticky world-writable ancestor (like /tmp) is still served.
sanc="$TMP/sticky-ancestor"; mkdir -m 1777 "$sanc"
mkdir -m 700 "$sanc/leaf"
slog="$sanc/leaf/forced-command.log"
sfc="$(render sticky "$slog")"
run "$sfc" "$EXPECTED"
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$OUT"; }
check 'ancestors: sticky 1777 ancestor permitted (no swap rights)' $?

# 10c. Symlinked ancestor is refused even when its target is valid.
vanc="$TMP/valid-ancestor"; mkdir -m 700 "$vanc"
lanc="$TMP/ancestor-alias"; ln -s "$vanc" "$lanc"
refused ancsym "$lanc/leaf-log"
check 'ancestors: symlinked ancestor refused' $?

# 10d. A non-directory ancestor component is refused.
midfile="$TMP/midfile"; : > "$midfile"
refused midfile "$midfile/leaf/forced-command.log"
check 'ancestors: non-directory component refused' $?

# 10e. Group-writable non-sticky ancestor is refused.
ganc="$TMP/group-ancestor"; mkdir -m 770 "$ganc"
mkdir -m 700 "$ganc/leaf"
refused ganc "$ganc/leaf/forced-command.log"
check 'ancestors: 0770 group-writable ancestor refused' $?

# -- 11. Deterministic write/open failures (ACM-966 item 1) -------------------
# 11a. Append fails at write time (RLIMIT_FSIZE=0, SIGXFSZ ignored -> EFBIG).
# Note: under fsize 0 stderr itself cannot be written to a file, so the only
# observable contract is rc=1 + stub not run + ledger byte-for-byte unchanged.
fulldir="$TMP/fulldir"; mkdir -m 700 "$fulldir"
fulllog="$fulldir/forced-command.log"
printf 'x%.0s' $(seq 1 600) > "$fulllog"; chmod 600 "$fulllog"
fullfc="$(render full "$fulllog")"
sh -c 'ulimit -f 0; exec env SSH_ORIGINAL_COMMAND="$1" SSH_CLIENT="10.9.9.9 5000 22" sh "$2"' \
    _ "$EXPECTED" "$fullfc" >"$TMP/out" 2>"$TMP/err" && RC=0 || RC=$?
{ [ "$RC" -eq 1 ] && ! grep -q 'STUB-EXECUTED' "$TMP/out" \
    && [ "$(wc -c < "$fulllog")" -eq 600 ]; }
check 'fail-closed: deterministic append failure refuses, stub not run' $?

# 11b. Open of the pinned descriptor fails (RLIMIT_NOFILE below fd 9). POSIX
# `exec` redirection failure may abort the shell before refuse() runs, so the
# contract is nonzero rc + stub not run, not a specific stderr message.
sh -c 'ulimit -n 9; exec env SSH_ORIGINAL_COMMAND="$1" SSH_CLIENT="10.9.9.9 5000 22" sh "$2"' \
    _ "$EXPECTED" "$freshfc" >"$TMP/out" 2>"$TMP/err" && RC=0 || RC=$?
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$TMP/out"; }
check 'fail-closed: deterministic descriptor-open failure refuses' $?

# -- 12. Python startup isolation (ACM-966 item 4) ----------------------------
TESTPY="$(command -v python3 || true)"
if [ -n "$TESTPY" ]; then
    PYHOME="$TMP/py-home"; mkdir -m 700 "$PYHOME"
    PYSNIPE="$TMP/pysnipe.py"; printf 'print("STUB-EXECUTED")\n' > "$PYSNIPE"
    usite=$(env HOME="$PYHOME" "$TESTPY" -c 'import site; print(site.getusersitepackages())' 2>/dev/null) || usite=
    if [ -n "$usite" ]; then
        mkdir -p "$usite"
        marker="$TMP/pth-marker"
        printf 'import pathlib;pathlib.Path(%s).write_text("x")\n' "'$marker'" > "$usite/probe.pth"
        # Control: plain interpreter run DOES fire the .pth under this HOME.
        env -i HOME="$PYHOME" PATH=/usr/bin:/bin "$TESTPY" -B "$PYSNIPE" >/dev/null 2>&1 || true
        control_fired=no; [ -e "$marker" ] && control_fired=yes
        rm -f "$marker"
        pylg="$TMP/pylogdir"; mkdir -m 700 "$pylg"
        pyfc="$(render pyiso "$pylg/forced-command.log" "$TESTPY" "$PYSNIPE" "$PYHOME")"
        PYEXP="$TESTPY -B $PYSNIPE --account $ACCOUNT"
        env SSH_ORIGINAL_COMMAND="$PYEXP" SSH_CLIENT='10.9.9.9 5000 22' \
            sh "$pyfc" >"$TMP/out" 2>"$TMP/err" && RC=0 || RC=$?
        { [ "$control_fired" = yes ] && [ "$RC" -eq 0 ] \
            && grep -q 'STUB-EXECUTED' "$TMP/out" && [ ! -e "$marker" ]; }
        check 'python: user-site .pth cannot execute through pinned entry' $?
    else
        bad 'python: could not compute user-site for probe'
    fi
else
    bad 'python: no python3 available for .pth probe'
fi

# -- 13. authorized_keys launch form -----------------------------------------
# sshd parses command="VALUE" (\" unescapes to literal ") then runs `sh -c VALUE`.
akvalue() { printf %s "$1" | sed 's/\\"/"/g'; }

# 13a. Space-free installed path: `sh -c` receives the bare path and runs it.
val="$(akvalue "$TESTFC")"
SSH_ORIGINAL_COMMAND="$EXPECTED" SSH_CLIENT='10.9.9.9 5000 22' \
    /bin/sh -c "$val" >"$TMP/out" 2>"$TMP/err" && RC=0 || RC=$?
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$TMP/out"; }
check 'launch: space-free authorized_keys path executes via sh -c' $?

# 13b. Escaped-quote form survives a spaced path (the corrected quoting rule).
spaced="$TMP/Application Support"; mkdir -p "$spaced"
spacedfc="$spaced/pigi_forced_command.sh"
cp "$TESTFC" "$spacedfc"; chmod 700 "$spacedfc"
stored="\"$spacedfc\""                       # what authorized_keys stores
val="$(akvalue "$stored")"                   # what `sh -c` receives
SSH_ORIGINAL_COMMAND="$EXPECTED" SSH_CLIENT='10.9.9.9 5000 22' \
    /bin/sh -c "$val" >"$TMP/out" 2>"$TMP/err" && RC=0 || RC=$?
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$TMP/out"; }
check 'launch: escaped-quote spaced path executes via sh -c' $?

# 13c. The documented authorized_keys entry itself, end to end.
ak_line="from=\"192.0.2.10\",restrict,command=\"\\\"$spacedfc\\\"\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeSyntheticKeyMaterialForTestingOnlyx"
cmdval=$(printf %s "$ak_line" | sed -n -E 's/.*command="((\\.|[^"])*)" ssh-.*/\1/p' | sed 's/\\"/"/g')
SSH_ORIGINAL_COMMAND="$EXPECTED" SSH_CLIENT='10.9.9.9 5000 22' \
    /bin/sh -c "$cmdval" >"$TMP/out" 2>"$TMP/err" && RC=0 || RC=$?
{ [ "$RC" -eq 0 ] && grep -q '^STUB-EXECUTED' "$TMP/out"; }
check 'launch: full authorized_keys line parses and runs spaced path' $?

# -- 14. ssh client config / known_hosts consistency --------------------------
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

# -- 15. Runbook invariants (ACM-966 items 5/6) -------------------------------
DOC="$ROOT/../../docs/billing-ssh-transition.md"
if [ -f "$DOC" ]; then
    # The deploy object is merged main; HEAD must NOT be required to equal
    # the reviewed candidate (a merge commit always has a new SHA).
    ! grep -q 'rev-parse HEAD.*equals the accepted SHA' "$DOC" \
        && grep -q 'merged `main` HEAD' "$DOC" \
        && grep -q 'merge-base --is-ancestor' "$DOC" \
        && grep -q 'diff --exit-code' "$DOC"
    check 'runbook: deploy verifies ancestor + tree equality, not HEAD == candidate' $?
    # Rollback restores recorded prior state; never overwrite-then-delete.
    grep -q 'recorded prior state' "$DOC" \
        && grep -q 'never overwrite a pre-existing object' "$DOC" \
        && ! grep -q 'rollback = delete file$' "$DOC"
    check 'runbook: rollback restores prior state, no overwrite-then-delete' $?
    grep -q 'required by default' "$DOC" && grep -q 'STOP' "$DOC"
    check 'runbook: from= stays mandatory and gaps STOP the rollout' $?
    # Every object the pinned pipeline can auto-create is inventoried with a
    # per-object policy, and audit objects are retained — not deleted.
    grep -q 'pigi-mcp/audit\.sqlite3' "$DOC" \
        && grep -q 'pigi-mail-read' "$DOC" \
        && grep -q 'audit record' "$DOC" \
        && grep -q 'RETAIN' "$DOC" \
        && ! grep -q 'leaves nothing behind' "$DOC"
    check 'runbook: runtime auto-created objects inventoried, audit retained' $?
else
    check 'runbook: docs/billing-ssh-transition.md exists' 1
fi

# -- 16. Synchronous same-UID swap windows (ACM-967 item 1) -------------------
# render_hook injects ONE literal line before a unique anchor in the rendered
# copy — deterministic race coverage at each check→open→append boundary.
# These are same-UID synthetic windows only; cross-UID is not safely testable.
render_hook() { # render_hook <name> <log> <anchor-substring> <injected-line>
    out="$TMP/fc-r$1.sh"
    sed -e "s|^readonly PIGI_FC_HOME=.*|readonly PIGI_FC_HOME='$THOME'|" \
        -e "s|^readonly PIGI_MCP_PYTHON=.*|readonly PIGI_MCP_PYTHON='$STUB'|" \
        -e "s|^readonly PIGI_MCP_SCRIPT=.*|readonly PIGI_MCP_SCRIPT='$SCRIPT_PATH'|" \
        -e "s|^readonly PIGI_MCP_ACCOUNT=.*|readonly PIGI_MCP_ACCOUNT='$ACCOUNT'|" \
        -e "s|^readonly PIGI_FC_LOG=.*|readonly PIGI_FC_LOG='$2'|" \
        "$FC" | awk -v anchor="$3" -v ins="$4" \
        'index($0,anchor){print ins} {print}' > "$out"
    chmod 700 "$out"
    # The injection is verified by line count: exactly one inserted line per
    # anchor occurrence (awk -v escape processing makes grep -F unreliable).
    n_anchors=$(awk -v a="$3" 'index($0,a){c++} END{print c+0}' "$FC")
    [ "$n_anchors" -ge 1 ] \
        && [ "$(wc -l < "$out")" -eq "$(( $(wc -l < "$FC") + n_anchors ))" ] \
        || { echo "hook inject failed: $1" >&2; exit 2; }
    printf %s "$out"
}
rdir="$TMP/race"; mkdir -m 700 "$rdir"

# 16a. chmod the validated inode between the checks and the open.
ra="$rdir/a"; mkdir -m 700 "$ra"; rloga="$ra/forced-command.log"
echo orig > "$rloga"; chmod 600 "$rloga"
hfc="$(render_hook a "$rloga" '{ exec 9>>' "    chmod 644 \"$rloga\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT"; }
check 'race: chmod in check→open window refused' $?

# 16b. Same-UID 0644 replacement staged between the checks and the open.
rb="$rdir/b"; mkdir -m 700 "$rb"; rlogb="$rb/forced-command.log"
echo orig > "$rlogb"; chmod 600 "$rlogb"
unsafe="$rb/unsafe"; echo unsafe > "$unsafe"; chmod 644 "$unsafe"
hfc="$(render_hook b "$rlogb" '{ exec 9>>' "    mv \"$unsafe\" \"$rlogb\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ "$(cat "$rlogb")" = 'unsafe' ]; }
check 'race: 0644 replacement before open refused, bad file untouched' $?

# 16c. Policy-compliant 0600 replacement still refused (identity changed).
rc_="$rdir/c"; mkdir -m 700 "$rc_"; rlogc="$rc_/forced-command.log"
echo orig > "$rlogc"; chmod 600 "$rlogc"
other="$rc_/other"; echo other > "$other"; chmod 600 "$other"
hfc="$(render_hook c "$rlogc" '{ exec 9>>' "    mv \"$other\" \"$rlogc\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ "$(cat "$rlogc")" = 'other' ]; }
check 'race: valid-mode replacement before open refused (inode mismatch)' $?

# 16d. Leaf directory swapped to a symlink between traversal and open.
rd="$rdir/d"; mkdir -m 700 "$rd"; rlogd="$rd/forced-command.log"
echo orig > "$rlogd"; chmod 600 "$rlogd"
rrepl="$rdir/repl"; mkdir -m 700 "$rrepl"; echo repl > "$rrepl/forced-command.log"
chmod 600 "$rrepl/forced-command.log"
hfc="$(render_hook d "$rlogd" '{ exec 9>>' \
    "    mv \"$rd\" \"$rdir/d-old\"; ln -s \"$rrepl\" \"$rd\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ "$(cat "$rrepl/forced-command.log")" = 'repl' ]; }
check 'race: ancestor symlink swap before open refused, target untouched' $?

# 16e. Path detached after the open (pre-emit): gate demotes to deny/detached
# and the record still lands on the pinned inode only.
re_="$rdir/e"; mkdir -m 700 "$re_"; rloge="$re_/forced-command.log"
echo orig > "$rloge"; chmod 600 "$rloge"
saved="$re_/saved"
hfc="$(render_hook e "$rloge" 'if ! ledger_gate' \
    "    mv \"$rloge\" \"$saved\"; printf 'decoy\\\\n' > \"$rloge\"; chmod 600 \"$rloge\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ "$(cat "$rloge")" = 'decoy' ] \
    && grep -q 'deny' "$saved" && grep -q 'detached' "$saved"; }
check 'race: post-open detach refused, record on pinned inode only' $?

# 16f. chmod between pre-emit gate and emit: refused BEFORE any byte written —
# the emit statement's own fd check catches it, so nothing reaches the file.
rf_="$rdir/f"; mkdir -m 700 "$rf_"; rlogf="$rf_/forced-command.log"
echo orig > "$rlogf"; chmod 600 "$rlogf"
hfc="$(render_hook f "$rlogf" 'if ! { ledger_fd_ok' "    chmod 644 \"$rlogf\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ "$(cat "$rlogf")" = 'orig' ]; }
check 'race: chmod before emit refused, nothing written to wide file' $?

# 16g. Hard link added between prepare and the first gate: nlink=2 refused.
rg_="$rdir/g"; mkdir -m 700 "$rg_"; rlogg="$rg_/forced-command.log"
echo orig > "$rlogg"; chmod 600 "$rlogg"
savedg="$rg_/saved"
hfc="$(render_hook g "$rlogg" 'if ! ledger_gate' "    ln \"$rlogg\" \"$savedg\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ "$(cat "$rlogg")" = 'orig' ]; }
check 'race: hard link before first gate refused, nothing appended' $?

# 16h. Leaf dir moved aside then symlinked to the SAME directory (identity
# unchanged, ancestor trust violated): refused.
rh_="$rdir/h"; mkdir -m 700 "$rh_"; rlogh="$rh_/forced-command.log"
echo orig > "$rlogh"; chmod 600 "$rlogh"
hfc="$(render_hook h "$rlogh" 'if ! ledger_gate' \
    "    mv \"$rh_\" \"$rdir/h-old\"; ln -s \"$rdir/h-old\" \"$rh_\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT"; }
check 'race: leaf-dir-to-symlink same inode refused (ancestor trust)' $?

# 16i. Hard link added before the final gate (post-emit): record was written
# while the inode still met policy; the gate refuses before serving.
ri_="$rdir/i"; mkdir -m 700 "$ri_"; rlogi="$ri_/forced-command.log"
echo orig > "$rlogi"; chmod 600 "$rlogi"
savedi="$ri_/saved"
hfc="$(render_hook i "$rlogi" '# Final gate immediately before exec:' \
    "    ln \"$rlogi\" \"$savedi\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && grep -q 'allow' "$rlogi"; }
check 'race: hard link at final gate refused' $?

# 16j. chmod at the final gate (post-emit): record written while valid; refuse.
rj_="$rdir/j"; mkdir -m 700 "$rj_"; rlogj="$rj_/forced-command.log"
echo orig > "$rlogj"; chmod 600 "$rlogj"
hfc="$(render_hook j "$rlogj" '# Final gate immediately before exec:' \
    "    chmod 644 \"$rlogj\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && grep -q 'allow' "$rlogj"; }
check 'race: chmod at final gate refused' $?

# 16k. Detach at the final gate: refuse, decoy untouched.
rk_="$rdir/k"; mkdir -m 700 "$rk_"; rlogk="$rk_/forced-command.log"
echo orig > "$rlogk"; chmod 600 "$rlogk"
savedk="$rk_/saved"
hfc="$(render_hook k "$rlogk" 'ledger_gate || refuse' \
    "    mv \"$rlogk\" \"$savedk\"; printf 'decoy\\\\n' > \"$rlogk\"; chmod 600 \"$rlogk\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ "$(cat "$rlogk")" = 'decoy' ]; }
check 'race: detach at final gate refused' $?

# 16l. A dangling symlink at the ledger path must refuse WITHOUT creating its
# target (no side effects on refusal).
rl_="$rdir/l"; mkdir -m 700 "$rl_"; rlogl="$rl_/forced-command.log"
dangle="$rl_/should-not-exist"; ln -s "$dangle" "$rlogl"
hfc="$(render dangle "$rlogl")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" && [ ! -e "$dangle" ]; }
check 'fail-closed: dangling symlink refused, target never created' $?

# 16m. Missing fstat dependency (/usr/bin/perl): fail closed.
rm_="$rdir/m"; mkdir -m 700 "$rm_"; rlogm="$rm_/forced-command.log"
pfc="$TMP/fc-rm.sh"
sed -e "s|^readonly PIGI_FC_HOME=.*|readonly PIGI_FC_HOME='$THOME'|" \
    -e "s|^readonly PIGI_MCP_PYTHON=.*|readonly PIGI_MCP_PYTHON='$STUB'|" \
    -e "s|^readonly PIGI_MCP_SCRIPT=.*|readonly PIGI_MCP_SCRIPT='$SCRIPT_PATH'|" \
    -e "s|^readonly PIGI_MCP_ACCOUNT=.*|readonly PIGI_MCP_ACCOUNT='$ACCOUNT'|" \
    -e "s|^readonly PIGI_FC_LOG=.*|readonly PIGI_FC_LOG='$rlogm'|" \
    -e 's|/usr/bin/perl|/nonexistent-synthetic-perl|g' \
    "$FC" > "$pfc"; chmod 700 "$pfc"
run "$pfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT"; }
check 'fail-closed: missing fstat helper refuses' $?

# 16n. Leaf dir is a symlink to a real 0700 dir and the log is absent: refuse
# BEFORE creating anything — the symlink target must not gain a file.
rn_="$rdir/n-target"; mkdir -m 700 "$rn_"
aliasn="$rdir/n-alias"; ln -s "$rn_" "$aliasn"
hfc="$(render n "$aliasn/forced-command.log")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ ! -e "$rn_/forced-command.log" ]; }
check 'creation: refused symlinked dir never gains a created file' $?

# 16o. Missing leaf dir with a refused ancestor: no mkdir side effect at all.
ro_="$rdir/o-anc"; mkdir -m 700 "$ro_"; ln -s "$ro_" "$rdir/o-link"
hfc="$(render o "$rdir/o-link/leaf/forced-command.log")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ ! -e "$ro_/leaf" ]; }
check 'creation: refused ancestor never gains a created dir' $?

# 16p. Ancestor swapped in the check→mkdir window: mkdir is cleaned up on
# refusal (rmdir of our own empty dir), leaving no residue.
rp_="$rdir/p-anc"; mkdir -m 700 "$rp_"
hfc="$(render_hook p "$rp_/leaf/forced-command.log" 'mkdir -m 700' \
    "    mv \"$rp_\" \"$rdir/p-old\"; ln -s \"$rdir/p-old\" \"$rp_\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT"; }
check 'creation: check→mkdir ancestor swap refused' $?

# 16q. Dangling link planted between -L check and atomic create: O_NOFOLLOW
# refuses the open — target never materializes.
rq_="$rdir/q"; mkdir -m 700 "$rq_"; rlogq="$rq_/forced-command.log"
qtarget="$rq_/should-not-exist"
hfc="$(render_hook q "$rlogq" 'O_NOFOLLOW' "    ln -s \"$qtarget\" \"$rlogq\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ ! -e "$qtarget" ]; }
check 'creation: link planted in check→create window refused, no target' $?

# 16r. Leaf dir swapped to symlink at emit time (same inode): the emit's own
# path check refuses — nothing appended.
rr_="$rdir/r"; mkdir -m 700 "$rr_"; rlogr="$rr_/forced-command.log"
echo orig > "$rlogr"; chmod 600 "$rlogr"
hfc="$(render_hook r "$rlogr" 'if ! { ledger_fd_ok' \
    "    mv \"$rr_\" \"$rdir/r-old\"; ln -s \"$rdir/r-old\" \"$rr_\"")"
run "$hfc" "$EXPECTED"
{ [ "$RC" -ne 0 ] && ! grep -q 'STUB-EXECUTED' "$OUT" \
    && [ "$(cat "$rlogr")" = 'orig' ]; }
check 'race: ancestor swap at emit refused, nothing written' $?

# -- 17. Runtime objects auto-created by the pinned pipeline (ACM-967 item 6) --
# Drive the REAL adapter through the forced command under a synthetic HOME and
# EOF stdin: it must create exactly the inventoried audit set, nothing else.
TESTPY=
for cand in "$(awk -F"'" '/^readonly PIGI_MCP_PYTHON=/{print $2}' "$FC")" \
            "$(command -v python3 || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ] \
        && "$cand" -c 'import sys;sys.exit(sys.version_info<(3,10))' 2>/dev/null; then
        TESTPY=$cand; break
    fi
done
if [ -n "$TESTPY" ]; then
    adhome="$TMP/adhome"; mkdir -m 700 "$adhome"
    adled="$TMP/adled"; mkdir -m 700 "$adled"; adlog="$adled/forced-command.log"
    adfc="$(render adapter "$adlog" "$TESTPY" "$ROOT/pigi_mcp.py" "$adhome")"
    EXPAD="$TESTPY -B $ROOT/pigi_mcp.py --account $ACCOUNT"
    run "$adfc" "$EXPAD" </dev/null
    created_f=$(cd "$adhome" && find . -type f | sort)
    created_d=$(cd "$adhome" && find . -type d | sort)
    expected_d='.
./Library
./Library/Application Support
./Library/Application Support/pigi-mcp'
    { [ "$created_f" = './Library/Application Support/pigi-mcp/audit.sqlite3' ] \
        && [ "$created_d" = "$expected_d" ] \
        && [ "$(stat -f %Lp "$adhome/Library/Application Support/pigi-mcp")" = 700 ] \
        && [ "$(stat -f %Lp "$adhome/Library/Application Support/pigi-mcp/audit.sqlite3")" = 600 ]; }
    check 'runtime-objects: adapter auto-creates only the inventoried audit set' $?
else
    check 'runtime-objects: python3 present for adapter probe' 1
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
