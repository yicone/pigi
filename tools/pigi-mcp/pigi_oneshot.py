#!/usr/bin/env python3
"""Hardened one-shot reader over the account-scoped pigi-mcp adapter. Python 3.10+, stdlib only.

The historical command line is the billing profile. A leading argv token
selects billing or full; the environment never does. The full profile's
commands live in pigi_oneshot_full.py.
"""
# Only os and sys may be imported before the trusted-entry gate: both are
# already in sys.modules at interpreter startup, so nothing PYTHONPATH-
# controlled can run before the refusal below. Every other import, stdlib or
# sibling, must wait until after the gate — the only supported launch is
# pigi_oneshot.sh, which scrubs the environment and marks the run.
import os
import sys

# Pinned literals only; behavior never comes from the caller's environment.
PINNED_HOME = "/Users/tr"
PINNED_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
# The launcher sets this exact flag value after scrubbing the environment.
# It is a marker that an isolated launcher ran — a public constant, not a
# secret or authentication.
TRUSTED_FLAG_NAME = "PIGI_ONESHOT_LAUNCHER"
TRUSTED_FLAG_VALUE = "trusted-entry-v1"
EXIT_UNTRUSTED_ENTRY = 9
# Fixed-shape error documents; every exit path emits one JSON on stdout and
# nothing on stderr. These are plain strings because the gate below must be
# able to emit them before the json module is safe to import.
USAGE_ERROR_JSON = '{"contentTrust":"untrusted","error":"invalid_arguments"}'
CONFIG_ERROR_JSON = '{"contentTrust":"untrusted","error":"configuration_unavailable"}'
INTERNAL_ERROR_JSON = '{"contentTrust":"untrusted","error":"internal_error"}'
UNTRUSTED_ENTRY_JSON = '{"contentTrust":"untrusted","error":"untrusted_entry"}'


def trusted_entry():
    flags = sys.flags
    return (os.environ.get(TRUSTED_FLAG_NAME) == TRUSTED_FLAG_VALUE
            and flags.isolated and flags.no_site and flags.utf8_mode
            and getattr(flags, "dont_write_bytecode", sys.dont_write_bytecode))


if __name__ == "__main__" and not trusted_entry():
    sys.stdout.write(UNTRUSTED_ENTRY_JSON)
    sys.exit(EXIT_UNTRUSTED_ENTRY)

# -I keeps the script's own directory off sys.path (-P semantics); re-add the
# real directory so sibling modules resolve — never a caller-controlled path.
_SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

try:
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
except ImportError:
    sys.stdout.write(CONFIG_ERROR_JSON)
    sys.exit(6)

MAX_STDOUT = 65_536
TRUNCATION_NOTICE = "pigi-oneshot: output truncated at 65536 bytes"
CONFIG_PARTS = ("Library", "Application Support", "pigi", "oneshot.json")
# Profile names are fixed argv tokens. A missing token stays the billing
# command line so the deployed Billing invocation does not change.
PROFILE_BILLING = "billing"
PROFILE_FULL = "full"
PROFILES = (PROFILE_BILLING, PROFILE_FULL)
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


class ConfigError(Exception):
    pass


def valid_account(account):
    """True for a non-blank account of at most 1024 UTF-8 bytes. Not stripped."""
    return (isinstance(account, str) and bool(account.strip())
            and len(account.encode("utf-8")) <= 1024)


def read_config_file(path):
    """Read one outside config file, or raise ConfigError / OSError.

    The file must be a regular 0600 inode, one hard link, owned by the
    effective user, and not a symlink. Its parent must be a real directory
    owned by that user and not group- or world-writable.
    """
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
    return data


def load_config(home):
    """Return {"account": str, "senders": frozenset}; raise ConfigError otherwise."""
    try:
        data = read_config_file(Path(home).joinpath(*CONFIG_PARTS))
        doc = json.loads(data)
        if not isinstance(doc, dict) or set(doc) != {"account", "senders"}:
            raise ConfigError
        account, senders = doc["account"], doc["senders"]
        if not valid_account(account):
            raise ConfigError
        if (not isinstance(senders, list) or not senders or len(senders) > 64
                or any(not isinstance(item, str) or not item.strip()
                       or len(item.encode("utf-8")) > 1024 for item in senders)):
            raise ConfigError
        return {"account": account,
                "senders": frozenset(item.strip().lower() for item in senders)}
    except (OSError, ValueError):
        raise ConfigError from None


class Context:
    """Execution context; tests inject the socket, audit path, interpreter and clock."""

    def __init__(self, account, senders, socket_path=DEFAULT_SOCKET,
                 audit_db=DEFAULT_AUDIT, python=None, home=None, now_ms=None,
                 profile=None):
        self.account = account
        self.senders = frozenset(senders)
        self.socket_path = socket_path
        self.audit_db = audit_db
        self.python = python or sys.executable
        self.home = PINNED_HOME if home is None else home
        self.now_ms = now_ms or (lambda: time.time_ns() // 1_000_000)
        self.profile = PROFILE_BILLING if profile is None else profile


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
    """Never prints: rejections surface only as the exit-2 JSON on stdout."""

    def __init__(self, *args, **kwargs):
        kwargs["add_help"] = False
        super().__init__(*args, **kwargs)

    def error(self, message=None):
        raise SystemExit(EXIT_USAGE)

    def exit(self, status=0, message=None):
        raise SystemExit(status)


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


ID_COMMANDS = {"get": 1, "get-batch": 5}


def id_command(argv):
    """Namespace for `get`/`get-batch`, or None for any other command.

    These commands take only IDs and no options, so argparse never sees them:
    it would read an ID that starts with `-` as an option. A first `--` token
    is always the separator and is dropped. A literal `--` is never an ID: any
    further `--` token is rejected, as is a lone `--` (no ID left). Every other
    token must match MESSAGE_ID and is an ID, so `-x`, `--x`, `-` and
    option-shaped IDs such as `--limit` are all plain IDs.
    """
    if not argv or argv[0] not in ID_COMMANDS:
        return None
    command, tokens = argv[0], argv[1:]
    if tokens[:1] == ["--"]:
        tokens = tokens[1:]
    if "--" in tokens or not 1 <= len(tokens) <= ID_COMMANDS[command]:
        raise SystemExit(EXIT_USAGE)
    try:
        ids = [message_id(token) for token in tokens]
    except argparse.ArgumentTypeError:
        raise SystemExit(EXIT_USAGE) from None
    if command == "get":
        return argparse.Namespace(command=command, message_id=ids[0])
    return argparse.Namespace(command=command, message_ids=ids)


def build_parser():
    parser = Parser(prog="pigi-oneshot", allow_abbrev=False, description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("accounts", allow_abbrev=False)
    search = commands.add_parser("search", allow_abbrev=False)
    search.add_argument("--since-days", type=bounded_int(1, 30), default=7)
    search.add_argument("--limit", type=bounded_int(1, 20), default=10)
    return parser


def parse_args(argv):
    args = id_command(argv)
    if args is not None:
        return args
    return build_parser().parse_args(argv)


def run_command(args, ctx):
    if ctx.profile != PROFILE_BILLING:
        return EXIT_USAGE, USAGE_ERROR_JSON.encode("ascii")
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
    return code, stdout


def execute(argv, ctx):
    """Parse argv (no program name) and run it. Returns (exit_code, stdout_bytes)."""
    try:
        args = parse_args(argv)
    except SystemExit:
        return EXIT_USAGE, USAGE_ERROR_JSON.encode("ascii")
    try:
        return run_command(args, ctx)
    except Exception:
        return EXIT_INTERNAL, INTERNAL_ERROR_JSON.encode("ascii")


def select_profile(argv):
    """Return (profile, remaining argv). The environment is not consulted.

    A leading `billing` or `full` token is the only selector. Any other argv,
    including the historical billing command line, stays on the billing profile
    and is rejected by that parser before config or socket use.
    """
    if argv and argv[0] in PROFILES:
        return argv[0], argv[1:]
    return PROFILE_BILLING, argv


def run_main(argv):
    """Whole CLI flow as (exit_code, stdout_bytes); every failure maps to JSON."""
    try:
        if not trusted_entry():
            return EXIT_UNTRUSTED_ENTRY, UNTRUSTED_ENTRY_JSON.encode("ascii")
        os.umask(0o077)
        # The launcher executes this file as __main__. Bind that module under
        # its import name before any sibling import, so configuration errors
        # raised by the sibling are the same class this function catches.
        # A second loaded copy would miss this handler and exit 7.
        if __name__ == "__main__":
            sys.modules["pigi_oneshot"] = sys.modules[__name__]
        # Reject arguments before any config read or socket use.
        profile, rest = select_profile(argv)
        try:
            if profile == PROFILE_FULL:
                import pigi_oneshot_full as full_profile
                args = full_profile.parse_args(rest)
            else:
                args = parse_args(rest)
        except SystemExit:
            return EXIT_USAGE, USAGE_ERROR_JSON.encode("ascii")
        home = PINNED_HOME
        socket_path = Path(home) / "Library/Application Support/pigi/agent.sock"
        audit_db = Path(home) / "Library/Application Support/pigi-mcp/audit.sqlite3"
        if profile == PROFILE_FULL:
            config = full_profile.load_config(home)
            ctx = Context(config["account"], (), home=home, socket_path=socket_path,
                          audit_db=audit_db, profile=PROFILE_FULL)
            return full_profile.run_command(args, ctx)
        config = load_config(home)
        ctx = Context(config["account"], config["senders"], home=home,
                      socket_path=socket_path, audit_db=audit_db,
                      profile=PROFILE_BILLING)
        return run_command(args, ctx)
    except ConfigError:
        return EXIT_CONFIG, CONFIG_ERROR_JSON.encode("ascii")
    except SystemExit:
        raise
    except Exception:
        return EXIT_INTERNAL, INTERNAL_ERROR_JSON.encode("ascii")


def main():
    try:
        code, stdout = run_main(sys.argv[1:])
    except SystemExit:
        raise
    except BaseException:
        code, stdout = EXIT_INTERNAL, INTERNAL_ERROR_JSON.encode("ascii")
    try:
        sys.stdout.buffer.write(stdout)
        sys.stdout.buffer.flush()
    except (OSError, AttributeError):
        pass
    return code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException:
        try:
            sys.stdout.write(INTERNAL_ERROR_JSON)
        except Exception:
            pass
        sys.exit(7)
