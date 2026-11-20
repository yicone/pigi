"""Full-read profile for pigi-oneshot. Python 3.10+, stdlib only.

Selected only by the leading argv token `full` (see pigi_oneshot.select_profile).
One configured account, no sender allowlist, no caller-supplied account.
Not an entry point: pigi_oneshot.py imports this after its trusted-entry gate.
"""
import argparse
import unicodedata

import pigi_oneshot

CONFIG_NAME = "oneshot-full.json"
QUERY_MAX_CHARS = 128
QUERY_MAX_BYTES = 256
QUERY_MARKS = set(" ._+@-")
LIST_COMMAND = "list"
LIST_TOOL = "list_messages"


def config_path(home):
    return pigi_oneshot.Path(home).joinpath(*pigi_oneshot.CONFIG_PARTS[:-1], CONFIG_NAME)


def load_config(home):
    """Return {"account": str}. The billing shape, including senders, is refused."""
    try:
        data = pigi_oneshot.read_config_file(config_path(home))
        doc = pigi_oneshot.json.loads(data)
        if not isinstance(doc, dict) or set(doc) != {"account"}:
            raise pigi_oneshot.ConfigError
        account = doc["account"]
        if not pigi_oneshot.valid_account(account):
            raise pigi_oneshot.ConfigError
        return {"account": account}
    except (OSError, ValueError):
        raise pigi_oneshot.ConfigError from None


def query_text(value):
    """Caller search text: 1–128 chars, ≤256 UTF-8 bytes, letters/numbers/marks."""
    if (not isinstance(value, str) or not value.strip()
            or len(value) > QUERY_MAX_CHARS
            or len(value.encode("utf-8")) > QUERY_MAX_BYTES):
        raise argparse.ArgumentTypeError("invalid query")
    for char in value:
        if char in QUERY_MARKS:
            continue
        if unicodedata.category(char)[0] not in "LN":
            raise argparse.ArgumentTypeError("invalid query")
    return value


def build_parser():
    parser = pigi_oneshot.Parser(prog="pigi-oneshot full", allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("accounts", allow_abbrev=False)
    listing = commands.add_parser(LIST_COMMAND, allow_abbrev=False)
    listing.add_argument("--since-days", type=pigi_oneshot.bounded_int(1, 30), default=7)
    listing.add_argument("--limit", type=pigi_oneshot.bounded_int(1, 20), default=10)
    search = commands.add_parser("search", allow_abbrev=False)
    search.add_argument("--query", required=True, type=query_text)
    search.add_argument("--since-days", type=pigi_oneshot.bounded_int(1, 30), default=7)
    search.add_argument("--limit", type=pigi_oneshot.bounded_int(1, 20), default=10)
    get = commands.add_parser("get", allow_abbrev=False)
    get.add_argument("message_id", type=pigi_oneshot.message_id)
    batch = commands.add_parser("get-batch", allow_abbrev=False)
    batch.add_argument("message_ids", nargs="+", type=pigi_oneshot.message_id)
    return parser


def parse_args(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "get-batch" and len(args.message_ids) > 5:
        parser.error()
    return args


def window(args, ctx):
    return {"since": ctx.now_ms() - args.since_days * 86_400_000, "limit": args.limit}


def own_record(record, ctx):
    return isinstance(record, dict) and record.get("account") == ctx.account


def own_items(items, ctx):
    return isinstance(items, list) and all(own_record(item, ctx) for item in items)


def command_accounts(args, ctx):
    status, value = pigi_oneshot.single_call(ctx, "list_accounts", {})
    if status == "error":
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure(value)
    accounts = value.get("accounts")
    if not own_items(accounts, ctx):
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure("invalid_response")
    return pigi_oneshot.EXIT_OK, pigi_oneshot.envelope("accounts", {"accounts": accounts})


def command_list(args, ctx):
    status, value = pigi_oneshot.single_call(ctx, LIST_TOOL, window(args, ctx))
    if status == "error":
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure(value)
    items = value.get("items")
    if not own_items(items, ctx):
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure("invalid_response")
    return pigi_oneshot.EXIT_OK, pigi_oneshot.envelope(LIST_COMMAND, {"items": items})


def command_search(args, ctx):
    status, value = pigi_oneshot.single_call(ctx, "search", {
        "query": args.query, **window(args, ctx)})
    if status == "error":
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure(value)
    items = value.get("items")
    if not own_items(items, ctx):
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure("invalid_response")
    return pigi_oneshot.EXIT_OK, pigi_oneshot.envelope("search", {"items": items})


def command_get(args, ctx):
    status, value = pigi_oneshot.single_call(
        ctx, "get_message", {"account": ctx.account, "messageID": args.message_id})
    if status == "error":
        code = pigi_oneshot.EXIT_NOT_FOUND if value == "not_found" else pigi_oneshot.EXIT_UPSTREAM
        return code, pigi_oneshot.upstream_failure(value)
    message, text = value.get("message"), value.get("text")
    if not own_record(message, ctx) or not isinstance(text, str):
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure("invalid_response")
    return pigi_oneshot.EXIT_OK, pigi_oneshot.envelope("get", {"message": message, "text": text})


def command_get_batch(args, ctx):
    calls = [("get_message", {"account": ctx.account, "messageID": message_id})
             for message_id in args.message_ids]
    results, worst = [], pigi_oneshot.EXIT_OK
    for message_id, (status, value) in zip(
            args.message_ids, pigi_oneshot.mcp_session(ctx, calls)):
        if status == "error":
            if value == "not_found":
                results.append({"messageID": message_id, "status": "not_found"})
                worst = max(worst, pigi_oneshot.EXIT_NOT_FOUND)
            else:
                results.append({"messageID": message_id, "status": "error", "error": value})
                worst = max(worst, pigi_oneshot.EXIT_UPSTREAM)
            continue
        message, text = value.get("message"), value.get("text")
        if not own_record(message, ctx) or not isinstance(text, str):
            results.append({"messageID": message_id, "status": "error",
                            "error": "invalid_response"})
            worst = max(worst, pigi_oneshot.EXIT_UPSTREAM)
        else:
            results.append({"messageID": message_id, "status": "ok",
                            "message": message, "text": text})
    return worst, pigi_oneshot.envelope("get-batch", {"results": results})


def emit_full(payload):
    """Same 64 KiB JSON cap as billing. Item commands shrink like search."""
    body = pigi_oneshot.serialize(payload)
    if len(body) <= pigi_oneshot.MAX_STDOUT:
        return body, False
    command = payload.get("command")
    if command in {LIST_COMMAND, "search"} and isinstance(payload.get("items"), list):
        adapted = dict(payload)
        adapted["command"] = "search"
        if "filteredOut" not in payload:
            adapted["filteredOut"] = 0
        shrunk = pigi_oneshot.shrink_payload(adapted, len(body))
        shrunk["command"] = command
        if "filteredOut" not in payload:
            shrunk.pop("filteredOut", None)
        out = pigi_oneshot.serialize(shrunk)
        if len(out) <= pigi_oneshot.MAX_STDOUT:
            return out, True
    return pigi_oneshot.emit(payload)


def run_command(args, ctx):
    if getattr(ctx, "profile", None) != pigi_oneshot.PROFILE_FULL:
        return pigi_oneshot.EXIT_USAGE, pigi_oneshot.USAGE_ERROR_JSON.encode("ascii")
    try:
        if args.command == "accounts":
            code, payload = command_accounts(args, ctx)
        elif args.command == LIST_COMMAND:
            code, payload = command_list(args, ctx)
        elif args.command == "search":
            code, payload = command_search(args, ctx)
        elif args.command == "get":
            code, payload = command_get(args, ctx)
        else:
            code, payload = command_get_batch(args, ctx)
    except pigi_oneshot.UpstreamError as error:
        code, payload = pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure(error.code)
    stdout, truncated = emit_full(payload)
    if truncated and code == pigi_oneshot.EXIT_OK:
        code = pigi_oneshot.EXIT_TRUNCATED
    return code, stdout


def execute(argv, ctx):
    """Parse argv (no program name, no profile token) and run it."""
    try:
        args = parse_args(argv)
    except SystemExit:
        return pigi_oneshot.EXIT_USAGE, pigi_oneshot.USAGE_ERROR_JSON.encode("ascii")
    try:
        return run_command(args, ctx)
    except Exception:
        return pigi_oneshot.EXIT_INTERNAL, pigi_oneshot.INTERNAL_ERROR_JSON.encode("ascii")
