#!/bin/sh
# Server-side forced command for the Billing-restricted SSH key (ACM-963).
#
# authorized_keys pins this script for exactly one dedicated key. The script
# NEVER executes SSH_ORIGINAL_COMMAND: it compares the request with one pinned,
# account-scoped, read-only pigi-mcp pipeline, records a sanitized event in a
# fail-closed ledger, and execs only the fixed pipeline. No code path runs
# attacker-controlled input.
#
# Authorization inputs are the literals below only — never the environment.
# The pinned interpreter is re-exec'd via `env -i` with -E -S -X utf8: no
# PYTHON* variables, no site processing (no user/global site-packages, no .pth
# or other startup files), explicit UTF-8 stdio; imports resolve to the
# script's own directory plus the stdlib. Remaining sshd-side conditions
# (AcceptEnv off, PermitUserEnvironment off, no ~/.ssh/environment, no unvetted
# ~/.ssh/rc) are verified at rollout; see docs/billing-ssh-transition.md.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
IFS=$(printf ' \t\nx'); IFS=${IFS%x}
umask 077
unset BASH_ENV ENV CDPATH PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONINSPECT
# If a write is capped by RLIMIT_FSIZE, take the error instead of SIGXFSZ.
trap '' XFSZ 2>/dev/null || true

# --- pinned configuration (production literals) ---
# The offline self-test renders a throwaway copy with these five values
# replaced; it never edits this installed file.
readonly PIGI_FC_HOME='/Users/tr'
readonly PIGI_MCP_PYTHON='/Users/tr/.pyenv/versions/3.11.13/bin/python3'
readonly PIGI_MCP_SCRIPT='/Users/tr/Workspace/pigi/tools/pigi-mcp/pigi_mcp.py'
readonly PIGI_MCP_ACCOUNT='adhielgona@gmail.com'
readonly PIGI_FC_LOG='/Users/tr/Library/Application Support/pigi/forced-command.log'
# --- end pinned configuration ---

refuse() {
    printf 'pigi-mcp: %s\n' "$1" >&2
    exit 1
}

euid=$(id -u)

# Ancestor component: a real directory, not a symlink, owned by us or root,
# and not replaceable by others — either not group/world writable, or a sticky
# world-writable directory like /tmp where non-owners cannot rename entries.
dir_component_ok() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    m=$(stat -f %p "$1" 2>/dev/null) && [ -n "$m" ] || return 1
    u=$(stat -f %u "$1" 2>/dev/null) || return 1
    [ $((0$m & 022)) -eq 0 ] || [ $((0$m & 01000)) -ne 0 ] || return 1
    [ "$u" = "$euid" ] || [ "$u" = 0 ] || return 1
}

# dev:inode of a path (lstat) — the identity pair.
id_of() {
    stat -f '%d:%i' "$1" 2>/dev/null
}

# Real fstat metadata of an open descriptor as dev:ino:uid:mode:nlink. stat(1)
# on /dev/fd/N reports the fdesc node, not the open file, so the descriptor's
# own device and mode must come from fstat(2).
fd_meta() {
    /usr/bin/perl -e 'open(F,"<&=",shift) or exit 1; @s=stat(F); \
        printf "%d:%d:%d:%o:%d",$s[0],$s[1],$s[4],$s[2]&07777,$s[3]' "$1" \
        2>/dev/null
}

# Full path validation; prints the ledger's dev:inode on success. Run before
# AND after the open so a same-UID swap in either window is caught: a chmod or
# replacement during the check→open window re-fails policy on the second pass.
ledger_path_ok() {
    dir=$1
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    [ "$(stat -f %u "$dir" 2>/dev/null)" = "$euid" ] || return 1
    [ "$(stat -f %Lp "$dir" 2>/dev/null)" = "700" ] || return 1
    cur=$dir
    while :; do
        dir_component_ok "$cur" || return 1
        [ "$cur" = / ] && break
        cur=${cur%/*}
        [ -n "$cur" ] || cur=/
    done
    [ ! -L "$PIGI_FC_LOG" ] || return 1
    [ -f "$PIGI_FC_LOG" ] || return 1
    [ "$(stat -f %u "$PIGI_FC_LOG" 2>/dev/null)" = "$euid" ] || return 1
    [ "$(stat -f %Lp "$PIGI_FC_LOG" 2>/dev/null)" = "600" ] || return 1
    [ "$(stat -f %l "$PIGI_FC_LOG" 2>/dev/null)" = "1" ] || return 1
    id_of "$PIGI_FC_LOG"
}

# The ledger is a precondition for serving: if it cannot be validated, opened,
# or appended, refuse — the same fail-closed rule as the adapter's
# audit_unavailable. On success fd 9 is an append descriptor pinned to the
# fully validated inode.
ledger_prepare() {
    case $PIGI_FC_LOG in
        /*) ;;
        *) return 1 ;;
    esac
    dir=${PIGI_FC_LOG%/*}
    [ -n "$dir" ] || return 1
    if [ ! -d "$dir" ]; then
        mkdir -m 700 "$dir" 2>/dev/null || return 1
    fi
    if [ ! -e "$PIGI_FC_LOG" ]; then
        : >> "$PIGI_FC_LOG" 2>/dev/null || return 1
    fi
    id_a=$(ledger_path_ok "$dir") || return 1
    # A bare `exec 9>>... 2>/dev/null` would also send fd 2 to /dev/null for
    # the rest of the script; the group confines the suppression to open errors.
    { exec 9>>"$PIGI_FC_LOG" || return 1; } 2>/dev/null
    [ -f /dev/fd/9 ] || return 1
    fdinfo=$(fd_meta 9) || return 1
    # The open descriptor must name the very object just validated — a path
    # swap between the two changes dev:inode — and the descriptor's real
    # owner, mode, and link count must still meet ledger policy.
    [ "$(printf %s "$fdinfo" | cut -d: -f1,2)" = "$id_a" ] || return 1
    [ "$(printf %s "$fdinfo" | cut -d: -f3-)" = "$euid:600:1" ] || return 1
    # Re-run every path check post-open: swaps, chmods, and link tricks staged
    # inside the check→open window are caught here.
    [ "$(ledger_path_ok "$dir")" = "$id_a" ] || return 1
    return 0
}

# Just before append: the ledger path must still name the pinned descriptor's
# inode and still meet file policy. A detach staged after the open cannot
# redirect the fd-bound write, but it would leave the canonical path without
# this event — so it is refused and recorded to the pinned inode instead.
ledger_bound() {
    [ "$(stat -f %Lp "$PIGI_FC_LOG" 2>/dev/null)" = "600" ] \
        && [ ! -L "$PIGI_FC_LOG" ] && [ -f "$PIGI_FC_LOG" ] \
        && [ "$(id_of "$PIGI_FC_LOG")" = "$(fd_meta 9 | cut -d: -f1,2)" ]
}

expected="$PIGI_MCP_PYTHON -B $PIGI_MCP_SCRIPT --account $PIGI_MCP_ACCOUNT"
original="${SSH_ORIGINAL_COMMAND-}"

# Sanitized metadata only: a charset-checked peer, request byte length, and a
# truncated SHA-256 fingerprint for attempt correlation. The raw request is
# never written — it may carry secrets, newlines, or control characters.
peer_raw="${SSH_CLIENT%% *}"
case $peer_raw in
    ''|*[!0-9A-Fa-f.:]*) peer='invalid' ;;
    *) peer=$peer_raw ;;
esac
req_len=${#original}
if [ -n "$original" ]; then
    req_fp=$(printf %s "$original" | shasum -a 256 | cut -c1-16)
else
    req_fp='-'
fi

ledger_prepare || refuse 'audit ledger unavailable; refusing.'

if ! ledger_bound; then
    result=deny; reason=detached
elif [ -z "$original" ]; then
    result=deny; reason=empty
elif [ "$original" != "$expected" ]; then
    result=deny; reason=mismatch
elif [ ! -x "$PIGI_MCP_PYTHON" ] || [ ! -f "$PIGI_MCP_SCRIPT" ]; then
    result=deny; reason=pinned-unavailable
else
    result=allow; reason=exact
fi

if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$peer" "$result" "$reason" "$req_len" \
    "$req_fp" >&9 2>/dev/null; then
    refuse 'audit ledger unavailable; refusing.'
fi
# fd 9 stays open through the gates so each bound check can fstat it; refuse()
# exits anyway, and the exec below closes it in the child via `9>&-`.
ledger_bound || refuse 'audit ledger detached; refusing.'
[ "$result" = allow ] || refuse 'command not permitted (pinned account-scoped read only).'
# Final gate immediately before exec: a path detach staged between emit and
# now still refuses — the canonical path must name the inode holding the
# record. A swap in the remaining instruction-scale window cannot redirect
# the (already fd-written) record and is documented as a residual.
ledger_bound || refuse 'audit ledger detached; refusing.'

# The wire contract stays "python -B <script> --account <acct>"; the server
# adds -E -S -X utf8 isolation flags itself, so the approved request and the
# hardened interpreter invocation differ deliberately.
exec env -i HOME="$PIGI_FC_HOME" PATH="$PATH" \
    "$PIGI_MCP_PYTHON" -B -E -S -X utf8 "$PIGI_MCP_SCRIPT" --account "$PIGI_MCP_ACCOUNT" \
    9>&-
