#!/bin/sh
# Server-side forced command for the Billing-restricted SSH key (ACM-963).
#
# authorized_keys pins this script for exactly one dedicated key. This script
# NEVER executes SSH_ORIGINAL_COMMAND: it compares the client's request against
# one pinned, account-scoped, read-only pigi-mcp invocation, appends the attempt
# to a local ledger, and execs only the fixed pipeline. There is no code path
# that runs attacker-controlled input.
#
# The PIGI_MCP_* overrides exist only for the offline self-test. OpenSSH does
# not forward client environment unless sshd AcceptEnv is configured (default:
# none), so an SSH client cannot influence these values.
set -u
umask 077

PIGI_MCP_PYTHON="${PIGI_MCP_PYTHON:-/Users/tr/.pyenv/versions/3.11.13/bin/python3}"
PIGI_MCP_SCRIPT="${PIGI_MCP_SCRIPT:-/Users/tr/Workspace/pigi/tools/pigi-mcp/pigi_mcp.py}"
PIGI_MCP_ACCOUNT="${PIGI_MCP_ACCOUNT:-adhielgona@gmail.com}"
PIGI_FC_LOG="${PIGI_FC_LOG:-$HOME/Library/Application Support/pigi/forced-command.log}"

expected="$PIGI_MCP_PYTHON -B $PIGI_MCP_SCRIPT --account $PIGI_MCP_ACCOUNT"
original="${SSH_ORIGINAL_COMMAND:-}"
peer="${SSH_CLIENT%% *}"

# Append-only attempt ledger: UTC timestamp, source, requested command.
# Records requested commands only; never mail content, keys, or credentials.
mkdir -p "${PIGI_FC_LOG%/*}" 2>/dev/null
printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${peer:-unknown}" \
    "${original:-<empty>}" >> "$PIGI_FC_LOG" 2>/dev/null

if [ "$original" != "$expected" ]; then
    printf 'pigi-mcp: command not permitted (pinned account-scoped read only).\n' >&2
    exit 1
fi

exec "$PIGI_MCP_PYTHON" -B "$PIGI_MCP_SCRIPT" --account "$PIGI_MCP_ACCOUNT"
