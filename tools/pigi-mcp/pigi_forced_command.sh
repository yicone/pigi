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

# Directory-side validation: leaf dir plus every ancestor to /. Must pass
# BEFORE any mkdir or file create — a refused ancestor must never gain a
# created object as a side effect. On success dir_id holds the validated
# directory's dev:inode so later steps bind to the object, not the path.
ledger_dirs_ok() {
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
}

# Full path validation; prints the ledger's dev:inode on success. Run before
# AND after the open so a same-UID swap in either window is caught: a chmod or
# replacement during the check→open window re-fails policy on the second pass.
ledger_path_ok() {
    ledger_dirs_ok "$1" || return 1
    [ ! -L "$PIGI_FC_LOG" ] || return 1
    [ -f "$PIGI_FC_LOG" ] || return 1
    [ "$(stat -f %u "$PIGI_FC_LOG" 2>/dev/null)" = "$euid" ] || return 1
    [ "$(stat -f %Lp "$PIGI_FC_LOG" 2>/dev/null)" = "600" ] || return 1
    [ "$(stat -f %l "$PIGI_FC_LOG" 2>/dev/null)" = "1" ] || return 1
    id_of "$PIGI_FC_LOG"
}

# Descriptor policy on fd 9: fstat must name the validated object and its
# real owner/mode/link count must still meet ledger policy. Used inside the
# emit statement itself so no check→write gap exists between them.
ledger_fd_ok() {
    fdinfo=$(fd_meta 9) || return 1
    [ "$(printf %s "$fdinfo" | cut -d: -f1,2)" = "$LEDGER_ID" ] || return 1
    [ "$(printf %s "$fdinfo" | cut -d: -f3-)" = "$euid:600:1" ] || return 1
}

# Canonical-path policy: every ancestor, the leaf directory, and the ledger
# file must still validate, and the path must still name the pinned inode.
# Run at every gate — a same-UID change anywhere (swap, chmod, hard link,
# dir-to-symlink) fails one of these checks.
ledger_bound() {
    [ "$(ledger_path_ok "$dir")" = "$LEDGER_ID" ]
}

ledger_gate() {
    ledger_fd_ok && ledger_bound
}

# The ledger is a precondition for serving: if it cannot be validated, opened,
# or appended, refuse — the same fail-closed rule as the adapter's
# audit_unavailable. On success fd 9 is an append descriptor pinned to the
# fully validated inode, and dir/LEDGER_ID name it for later gates.
#
# Traversal, validation, mkdir and create run inside ONE perl process: each
# path component is lstat-validated, pinned on a descriptor, and re-checked
# on that descriptor before descending — validation always binds the object
# actually used, never a path snapshot. Only the leaf dir may be created,
# inside its pinned parent; the ledger file is created with
# O_CREAT|O_EXCL|O_NOFOLLOW inside the pinned leaf dir, so a name swapped in
# between the lstat and the open fails the syscall instead of being
# attributed to this run or overwritten. A refusal NEVER deletes anything:
# when an object's identity is in doubt it is retained — a file/dir this run
# created may be left inside the validated object at a moved path (accepted
# safety-first residue, reported in the runbook); a pre-existing or
# substitute object is never touched.
ledger_prepare() {
    case $PIGI_FC_LOG in
        /*) ;;
        *) return 1 ;;
    esac
    dir=${PIGI_FC_LOG%/*}
    leaf=${PIGI_FC_LOG##*/}
    [ -n "$dir" ] && [ -n "$leaf" ] || return 1
    /usr/bin/perl -e 'use Fcntl;
        my($dir,$leaf,$euid)=@ARGV;
        my @c=grep {length} split m{/},$dir; @c or exit 1;
        my @F;
        sysopen($F[0],q{/},O_RDONLY|O_DIRECTORY) or exit 1;
        for my $i (0..$#c) {
            chdir($F[$i]) or exit 2;
            my $comp=$c[$i]; my $last=($i==$#c);
            my @l=lstat($comp);
            if (!@l) {
                $last or exit 3;
                mkdir($comp,0700) or exit 4;
                @l=lstat($comp) or exit 3;
            }
            ($l[2]&0170000)==0040000 or exit 5;
            if ($last) {
                $l[4]==$euid or exit 6;
                ($l[2]&07777)==0700 or exit 7;
            } else {
                ($l[4]==$euid || $l[4]==0) or exit 8;
                my $m=$l[2]&07777;
                ($m&022)==0 or ($m&01000) or exit 9;
            }
            sysopen($F[$i+1],$comp,O_RDONLY|O_DIRECTORY) or exit 10;
            my @s=stat($F[$i+1]);
            ($s[0]==$l[0] && $s[1]==$l[1]) or exit 11;
            $s[4]==$l[4] && ($s[2]&07777)==($l[2]&07777) or exit 12;
        }
        chdir($F[$#F]) or exit 13;
        my @f=lstat($leaf);
        (@f && ($f[2]&0170000)==0120000) and exit 14;
        if (@f) {
            ($f[2]&0170000)==0100000 or exit 15;
            $f[4]==$euid or exit 16;
            ($f[2]&07777)==0600 or exit 17;
            $f[3]==1 or exit 18;
        } else {
            sysopen(F,$leaf,O_WRONLY|O_CREAT|O_EXCL|O_APPEND|O_NOFOLLOW,0600) or exit 19;
            close F;
        }
        exit 0' "$dir" "$leaf" "$euid" 2>/dev/null || return 1
    LEDGER_ID=$(ledger_path_ok "$dir") || return 1
    # A bare `exec 9>>... 2>/dev/null` would also send fd 2 to /dev/null for
    # the rest of the script; the group confines the suppression to open errors.
    { exec 9>>"$PIGI_FC_LOG" || return 1; } 2>/dev/null
    [ -f /dev/fd/9 ] || return 1
    # The open descriptor must name the very object just validated, and the
    # post-open pass re-runs every path check so anything staged inside the
    # check→open window is caught here.
    ledger_fd_ok || return 1
    ledger_bound || return 1
    return 0
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

if ! ledger_gate; then
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

# fd 9 stays open through the gates so each check can fstat it; refuse()
# exits anyway, and the exec below closes it in the child via `9>&-`.
# The emit statement re-checks the descriptor AND the canonical path (for
# allow) inside the same command — a staged change refuses BEFORE any byte
# is written, never "write first, refuse later". Every expansion inside the
# statement is a precomputed variable; no command substitution runs between
# the checks and the write. A change landing between the last check and the
# write is the documented instruction-scale residual. deny records still
# reach the pinned inode even when the canonical path detached.
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! { ledger_fd_ok \
        && { [ "$result" = deny ] || ledger_bound; } \
        && printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ts" "$peer" "$result" "$reason" "$req_len" "$req_fp" >&9; } \
    2>/dev/null; then
    refuse 'audit ledger unavailable; refusing.'
fi
[ "$result" = allow ] || refuse 'command not permitted (pinned account-scoped read only).'
# Final gate immediately before exec: full fd + path + ancestor checks — a
# detach or policy change staged between emit and now still refuses. A swap
# in the remaining instruction-scale window cannot redirect the (already
# fd-written) record; its real residual is documented in the runbook.
ledger_gate || refuse 'audit ledger detached; refusing.'

# The wire contract stays "python -B <script> --account <acct>"; the server
# adds -E -S -X utf8 isolation flags itself, so the approved request and the
# hardened interpreter invocation differ deliberately.
exec env -i HOME="$PIGI_FC_HOME" PATH="$PATH" \
    "$PIGI_MCP_PYTHON" -B -E -S -X utf8 "$PIGI_MCP_SCRIPT" --account "$PIGI_MCP_ACCOUNT" \
    9>&-
