#!/usr/bin/env python3
"""Hardened one-shot reader over the account-scoped pigi-mcp adapter. Python 3.10+, stdlib only."""
# Only os and sys may be imported before the hardening gate: both are already
# in sys.modules at interpreter startup, so nothing PYTHONPATH-controlled can
# run before the re-exec below. Every other import, stdlib or sibling, must
# wait until after the gate (under -E -S, PYTHONPATH and site are inert anyway).
import os
import sys

# Pinned literals only; behavior never comes from the caller's environment.
PINNED_PYTHON = "/Users/tr/.pyenv/versions/3.11.13/bin/python3"
PINNED_HOME = "/Users/tr"
PINNED_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
EXEC_ENV = {"HOME": PINNED_HOME, "PATH": PINNED_PATH}


def is_hardened():
    flags = sys.flags
    return bool(flags.ignore_environment and flags.no_site and flags.utf8_mode
                and getattr(flags, "dont_write_bytecode", sys.dont_write_bytecode))


def hardened_exec_args(argv):
    return [PINNED_PYTHON, "-B", "-E", "-S", "-X", "utf8",
            os.path.realpath(__file__), *argv[1:]]


if __name__ == "__main__" and not is_hardened():
    if not (os.path.isfile(PINNED_PYTHON) and os.access(PINNED_PYTHON, os.X_OK)):
        print("pigi-oneshot: pinned interpreter unavailable", file=sys.stderr)
        sys.exit(6)
    try:
        os.execve(PINNED_PYTHON, hardened_exec_args(sys.argv), EXEC_ENV)
    except OSError:
        print("pigi-oneshot: pinned interpreter unavailable", file=sys.stderr)
        sys.exit(6)

import argparse
import json
from pathlib import Path
import re
import stat
import subprocess
import time

from audit import DEFAULT_AUDIT
from pigi_mcp import PROTOCOL_VERSION, TRUST_NOTICE
from transport import DEFAULT_SOCKET

MAX_STDOUT = 65_536
TRUNCATION_NOTICE = "pigi-oneshot: output truncated at 65536 bytes"
CONFIG_PARTS = ("Library", "Application Support", "pigi", "oneshot.json")
SEARCH_QUERY = "Cursor"
MESSAGE_ID = re.compile(r"[A-Za-z0-9._@=+-]{1,256}")
CHILD_TIMEOUT = 20

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_SENDER_DENIED = 3
EXIT_NOT_FOUND = 4
EXIT_UPSTREAM = 5
EXIT_CONFIG = 6
EXIT_INTERNAL = 7
EXIT_TRUNCATED = 8

FAILURE_LINES = {EXIT_USAGE: "pigi-oneshot: invalid arguments",
                 EXIT_SENDER_DENIED: "pigi-oneshot: sender not on the allowlist",
                 EXIT_NOT_FOUND: "pigi-oneshot: not found",
                 EXIT_UPSTREAM: "pigi-oneshot: upstream error",
                 EXIT_TRUNCATED: "pigi-oneshot: output truncated"}


class ConfigError(Exception):
    pass


def load_config(home):
    """Return {"account": str, "senders": frozenset}; fail closed with exit 6."""
    try:
        path = Path(home).joinpath(*CONFIG_PARTS)
        parent = path.parent.lstat()
        if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid()
                or stat.S_IMODE(parent.st_mode) & 0o022):
            raise ConfigError
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise ConfigError
            data = os.read(fd, MAX_STDOUT + 1)
            if len(data) > MAX_STDOUT:
                raise ConfigError
        finally:
            os.close(fd)
        doc = json.loads(data)
        if not isinstance(doc, dict) or set(doc) != {"account", "senders"}:
            raise ConfigError
        account, senders = doc["account"], doc["senders"]
        if (not isinstance(account, str) or not account.strip()
                or len(account.encode("utf-8")) > 1024):
            raise ConfigError
        if (not isinstance(senders, list) or not senders or len(senders) > 64
                or any(not isinstance(item, str) or not item.strip()
                       or len(item.encode("utf-8")) > 1024 for item in senders)):
            raise ConfigError
        return {"account": account,
                "senders": frozenset(item.strip().lower() for item in senders)}
    except (OSError, ValueError, ConfigError):
        print("pigi-oneshot: configuration unavailable", file=sys.stderr)
        raise SystemExit(EXIT_CONFIG) from None


class Context:
    """Execution context; tests inject the socket, audit path, interpreter and clock."""

    def __init__(self, account, senders, socket_path=DEFAULT_SOCKET,
                 audit_db=DEFAULT_AUDIT, python=None, home=None, now_ms=None):
        self.account = account
        self.senders = frozenset(senders)
        self.socket_path = socket_path
        self.audit_db = audit_db
        self.python = python or sys.executable
        self.home = PINNED_HOME if home is None else home
        self.now_ms = now_ms or (lambda: time.time_ns() // 1_000_000)


class UpstreamError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def mcp_session(ctx, calls):
    """One pigi_mcp child: handshake, then each (tool, arguments) pair in order.

    Returns one ("ok", result) or ("error", fixed_code) per call; raises
    UpstreamError only when the session itself is unusable.
    """
    script = Path(__file__).resolve().with_name("pigi_mcp.py")
    command = [ctx.python, "-B", "-E", "-S", "-X", "utf8", str(script),
               "--account", ctx.account,
               "--socket", str(ctx.socket_path),
               "--audit-db", str(ctx.audit_db)]
    frames = [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
               "params": {"protocolVersion": PROTOCOL_VERSION, "capabilities": {},
                          "clientInfo": {"name": "pigi-oneshot", "version": "0.1.0"}}},
              {"jsonrpc": "2.0", "method": "notifications/initialized"}]
    for index, (name, arguments) in enumerate(calls, start=2):
        frames.append({"jsonrpc": "2.0", "id": index, "method": "tools/call",
                       "params": {"name": name, "arguments": arguments}})
    payload = b"".join(json.dumps(frame, ensure_ascii=True, allow_nan=False).encode("utf-8") + b"\n"
                       for frame in frames)
    try:
        child = subprocess.Popen(command, env={"HOME": ctx.home, "PATH": PINNED_PATH},
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
    except OSError:
        raise UpstreamError("upstream_unavailable") from None
    try:
        # Child stderr is captured and discarded, never forwarded.
        stdout, _stderr = child.communicate(input=payload, timeout=CHILD_TIMEOUT)
    except subprocess.TimeoutExpired:
        child.kill()
        child.communicate()
        raise UpstreamError("timeout") from None
    if child.returncode != 0:
        raise UpstreamError("upstream_unavailable")
    responses = {}
    for line in stdout.splitlines():
        try:
            message = json.loads(line)
        except ValueError:
            raise UpstreamError("invalid_response") from None
        if isinstance(message, dict) and type(message.get("id")) is int:
            responses[message["id"]] = message
    handshake = responses.get(1)
    if (not isinstance(handshake, dict) or "error" in handshake
            or not isinstance(handshake.get("result"), dict)):
        raise UpstreamError("upstream_unavailable")
    outcomes = []
    for index in range(2, len(calls) + 2):
        response = responses.get(index)
        if not isinstance(response, dict):
            raise UpstreamError("invalid_response")
        if "error" in response:
            outcomes.append(("error", "internal_error"))
            continue
        result = response.get("result")
        if not isinstance(result, dict) or type(result.get("isError")) is not bool:
            raise UpstreamError("invalid_response")
        content = result.get("content")
        text = None
        if (isinstance(content, list) and content and isinstance(content[0], dict)
                and isinstance(content[0].get("text"), str)):
            text = content[0]["text"]
        try:
            value = json.loads(text) if text is not None else None
        except ValueError:
            raise UpstreamError("invalid_response") from None
        if not isinstance(value, dict):
            raise UpstreamError("invalid_response")
        if result["isError"]:
            code = value.get("error")
            outcomes.append(("error", code if isinstance(code, str) else "invalid_response"))
            continue
        if value.get("contentTrust") != "untrusted":
            outcomes.append(("error", "invalid_response"))
            continue
        outcomes.append(("ok", value))
    return outcomes


def single_call(ctx, tool, arguments):
    outcome, = mcp_session(ctx, [(tool, arguments)])
    return outcome


def sender_allowed(from_email, ctx):
    return isinstance(from_email, str) and from_email.strip().lower() in ctx.senders


def envelope(command, payload):
    return {"contentTrust": "untrusted", "trustNotice": TRUST_NOTICE,
            "command": command, **payload}


def upstream_failure(code):
    return {"contentTrust": "untrusted", "error": code}


def command_accounts(args, ctx):
    status, value = single_call(ctx, "list_accounts", {})
    if status == "error":
        return EXIT_UPSTREAM, upstream_failure(value)
    accounts = value.get("accounts")
    if not isinstance(accounts, list):
        return EXIT_UPSTREAM, upstream_failure("invalid_response")
    return EXIT_OK, envelope("accounts", {"accounts": accounts})


def command_search(args, ctx):
    status, value = single_call(ctx, "search", {
        "query": SEARCH_QUERY, "since": ctx.now_ms() - args.since_days * 86_400_000,
        "limit": args.limit})
    if status == "error":
        return EXIT_UPSTREAM, upstream_failure(value)
    items = value.get("items")
    if not isinstance(items, list):
        return EXIT_UPSTREAM, upstream_failure("invalid_response")
    kept = [item for item in items if isinstance(item, dict)
            and sender_allowed(item.get("fromEmail"), ctx)]
    return EXIT_OK, envelope("search", {"items": kept, "filteredOut": len(items) - len(kept)})


def command_get(args, ctx):
    status, value = single_call(ctx, "get_message",
                                {"account": ctx.account, "messageID": args.message_id})
    if status == "error":
        code = EXIT_NOT_FOUND if value == "not_found" else EXIT_UPSTREAM
        return code, upstream_failure(value)
    message, text = value.get("message"), value.get("text")
    if not isinstance(message, dict) or not isinstance(text, str):
        return EXIT_UPSTREAM, upstream_failure("invalid_response")
    if not sender_allowed(message.get("fromEmail"), ctx):
        return EXIT_SENDER_DENIED, {"contentTrust": "untrusted", "trustNotice": TRUST_NOTICE,
                                   "allowed": False, "message": None}
    return EXIT_OK, envelope("get", {"message": message, "text": text})


def command_get_batch(args, ctx):
    calls = [("get_message", {"account": ctx.account, "messageID": message_id})
             for message_id in args.message_ids]
    results, worst = [], EXIT_OK
    for message_id, (status, value) in zip(args.message_ids, mcp_session(ctx, calls)):
        if status == "error":
            if value == "not_found":
                results.append({"messageID": message_id, "status": "not_found"})
                worst = max(worst, EXIT_NOT_FOUND)
            else:
                results.append({"messageID": message_id, "status": "error", "error": value})
                worst = max(worst, EXIT_UPSTREAM)
            continue
        message, text = value.get("message"), value.get("text")
        if not isinstance(message, dict) or not isinstance(text, str):
            results.append({"messageID": message_id, "status": "error",
                            "error": "invalid_response"})
            worst = max(worst, EXIT_UPSTREAM)
        elif not sender_allowed(message.get("fromEmail"), ctx):
            results.append({"messageID": message_id, "status": "filtered"})
            worst = max(worst, EXIT_SENDER_DENIED)
        else:
            results.append({"messageID": message_id, "status": "ok",
                            "message": message, "text": text})
    return worst, envelope("get-batch", {"results": results})


def serialize(payload):
    return json.dumps(payload, ensure_ascii=True, allow_nan=False,
                      separators=(",", ":")).encode("utf-8")


def shrink_payload(payload, original_bytes):
    """Cut the payload by shape so it serializes within MAX_STDOUT.

    Sizes are always measured on serialized bytes: ensure_ascii escapes can
    expand characters, so serialized output is never sliced directly.
    """
    base = {"contentTrust": payload.get("contentTrust", "untrusted"),
            "trustNotice": payload.get("trustNotice", TRUST_NOTICE),
            "command": payload.get("command"),
            "truncated": True, "truncationNotice": TRUNCATION_NOTICE,
            "originalBytes": original_bytes}
    command = payload.get("command")
    if command == "search" and isinstance(payload.get("items"), list):
        items = payload["items"]
        candidate = {**base, "items": [], "filteredOut": payload.get("filteredOut", 0),
                     "omittedItems": len(items)}
        low, high = 0, len(items)
        while low < high:
            middle = (low + high + 1) // 2
            candidate["items"] = items[:middle]
            candidate["omittedItems"] = len(items) - middle
            if len(serialize(candidate)) <= MAX_STDOUT:
                low = middle
            else:
                high = middle - 1
        candidate["items"] = items[:low]
        candidate["omittedItems"] = len(items) - low
        if len(serialize(candidate)) <= MAX_STDOUT:
            return candidate
    elif command == "get" and isinstance(payload.get("message"), dict):
        text = payload.get("text")
        if isinstance(text, str):
            candidate = {**base, "message": payload["message"], "text": "",
                         "textTruncated": True}
            low, high = 0, len(text)
            while low < high:
                middle = (low + high + 1) // 2
                candidate["text"] = text[:middle]
                if len(serialize(candidate)) <= MAX_STDOUT:
                    low = middle
                else:
                    high = middle - 1
            candidate["text"] = text[:low]
            if len(serialize(candidate)) <= MAX_STDOUT:
                return candidate
    elif command == "get-batch" and isinstance(payload.get("results"), list):
        results = payload["results"]

        def build(budget):
            cut = []
            for entry in results:
                entry = dict(entry)
                if (entry.get("status") == "ok" and isinstance(entry.get("text"), str)
                        and len(entry["text"]) > budget):
                    entry["text"] = entry["text"][:budget]
                    entry["textTruncated"] = True
                cut.append(entry)
            return {**base, "results": cut}

        longest = max((len(entry.get("text", "")) for entry in results
                       if entry.get("status") == "ok"), default=0)
        low, high = 0, longest
        while low < high:
            middle = (low + high + 1) // 2
            if len(serialize(build(middle))) <= MAX_STDOUT:
                low = middle
            else:
                high = middle - 1
        candidate = build(low)
        if len(serialize(candidate)) <= MAX_STDOUT:
            return candidate
    return base


def emit(payload):
    """Returns (stdout_bytes, truncated); stdout is always one JSON document."""
    if payload is None:
        return b"", False
    body = serialize(payload)
    if len(body) <= MAX_STDOUT:
        return body, False
    return serialize(shrink_payload(payload, len(body))), True


class Parser(argparse.ArgumentParser):
    def error(self, message=None):
        print(FAILURE_LINES[EXIT_USAGE], file=sys.stderr)
        raise SystemExit(EXIT_USAGE)


def bounded_int(low, high):
    def parse(value):
        try:
            number = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError("out of range") from None
        if not low <= number <= high:
            raise argparse.ArgumentTypeError("out of range")
        return number
    return parse


def message_id(value):
    if not MESSAGE_ID.fullmatch(value):
        raise argparse.ArgumentTypeError("invalid messageID")
    return value


def build_parser():
    parser = Parser(prog="pigi-oneshot", allow_abbrev=False, description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("accounts", allow_abbrev=False)
    search = commands.add_parser("search", allow_abbrev=False)
    search.add_argument("--since-days", type=bounded_int(1, 30), default=7)
    search.add_argument("--limit", type=bounded_int(1, 20), default=10)
    get = commands.add_parser("get", allow_abbrev=False)
    get.add_argument("message_id", type=message_id)
    batch = commands.add_parser("get-batch", allow_abbrev=False)
    batch.add_argument("message_ids", nargs="+", type=message_id)
    return parser


def parse_args(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "get-batch" and len(args.message_ids) > 5:
        parser.error()
    return args


def run_command(args, ctx):
    try:
        if args.command == "accounts":
            code, payload = command_accounts(args, ctx)
        elif args.command == "search":
            code, payload = command_search(args, ctx)
        elif args.command == "get":
            code, payload = command_get(args, ctx)
        else:
            code, payload = command_get_batch(args, ctx)
    except UpstreamError as error:
        code, payload = EXIT_UPSTREAM, upstream_failure(error.code)
    stdout, truncated = emit(payload)
    if truncated and code == EXIT_OK:
        code = EXIT_TRUNCATED
    if code in FAILURE_LINES:
        print(FAILURE_LINES[code], file=sys.stderr)
    return code, stdout


def execute(argv, ctx):
    """Parse argv (no program name) and run it. Returns (exit_code, stdout_bytes)."""
    try:
        args = parse_args(argv)
    except SystemExit as exit_:
        code = exit_.code if isinstance(exit_.code, int) else EXIT_USAGE
        return code, b""
    try:
        return run_command(args, ctx)
    except Exception:
        print("pigi-oneshot: internal error", file=sys.stderr)
        return EXIT_INTERNAL, b""


def main():
    if not is_hardened():
        if not (os.path.isfile(PINNED_PYTHON) and os.access(PINNED_PYTHON, os.X_OK)):
            print("pigi-oneshot: pinned interpreter unavailable", file=sys.stderr)
            return EXIT_CONFIG
        try:
            os.execve(PINNED_PYTHON, hardened_exec_args(sys.argv), EXEC_ENV)
        except OSError:
            print("pigi-oneshot: pinned interpreter unavailable", file=sys.stderr)
            return EXIT_CONFIG
    os.umask(0o077)
    argv = sys.argv[1:]
    # Reject arguments before any config read or socket use.
    try:
        args = parse_args(argv)
    except SystemExit as exit_:
        return exit_.code if isinstance(exit_.code, int) else EXIT_USAGE
    home = PINNED_HOME
    config = load_config(home)
    ctx = Context(config["account"], config["senders"], home=home,
                  socket_path=Path(home) / "Library/Application Support/pigi/agent.sock",
                  audit_db=Path(home) / "Library/Application Support/pigi-mcp/audit.sqlite3")
    try:
        code, stdout = run_command(args, ctx)
    except Exception:
        print("pigi-oneshot: internal error", file=sys.stderr)
        return EXIT_INTERNAL
    try:
        sys.stdout.buffer.write(stdout)
        sys.stdout.buffer.flush()
    except OSError:
        pass
    return code


if __name__ == "__main__":
    sys.exit(main())
