"""Full-read profile for pigi-oneshot. Python 3.10+, stdlib only.

Selected only by the leading argv token `full` (see pigi_oneshot.select_profile).
One configured account, no sender allowlist, no caller-supplied account.
Not an entry point: pigi_oneshot.py imports this after its trusted-entry gate.
"""
import argparse
import base64
import hashlib
import unicodedata

import pigi_oneshot

CONFIG_NAME = "oneshot-full.json"
QUERY_MAX_CHARS = 128
QUERY_MAX_BYTES = 256
QUERY_MARKS = set(" ._+@-")
LIST_COMMAND = "list"
LIST_TOOL = "list_messages"
HISTORY_MAX_DAYS = 365
BACK = 40
WINDOW = 100
CURSOR_MAX_CHARS = 1024
MAX_SAFE_MS = 9_007_199_254_740_991
CURSOR_TTL_MS = 6 * 3_600_000
CLOCK_SKEW_MS = 60_000
IDENTITY_FIELDS = {"account", "messageID", "date"}
META_BUDGET = 512
CODES_COMMAND = "codes"
CODES_TOOL = "get_verification_code"
CODES_STATUSES = ("inbox", "archived", "spam", "trash")
CODES_FIELDS = ("code", "fromName", "fromEmail", "date", "account", "messageID")
CODES_SINCE_DEFAULT_MINUTES = 10
CODES_SINCE_MAX_MINUTES = 60
CODES_OFFSET_MAX = 1_000_000
CODES_FETCH = 100
CODES_MAX_FETCHES = 5
CODES_MAX_SENDERS = 64


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


def query_digest(query):
    return hashlib.sha256(query.encode("utf-8")).hexdigest()[:16]


def sender_filter(value):
    """--from-email: non-blank, at most 1024 UTF-8 bytes; stored lowercased."""
    if (not isinstance(value, str) or not value.strip()
            or len(value.encode("utf-8")) > 1024):
        raise argparse.ArgumentTypeError("invalid sender")
    return value.strip().lower()


def cursor(value):
    """--cursor token: strict structure; subcommand/query binding is checked
    later in parse_args, the `s` time bound in run_command."""
    try:
        if len(value) > CURSOR_MAX_CHARS:
            raise ValueError
        doc = pigi_oneshot.json.loads(base64.b64decode(
            (value + "=" * (-len(value) % 4)).encode("ascii"),
            altchars=b"-_", validate=True))
        if (not isinstance(doc, dict)
                or set(doc) != {"v", "c", "q", "s", "o", "d", "i"}
                or type(doc["v"]) is not int or doc["v"] != 1
                or not isinstance(doc["c"], str)
                or not isinstance(doc["q"], str)
                or type(doc["s"]) is not int
                or not 0 < doc["s"] <= MAX_SAFE_MS
                or type(doc["o"]) is not int or not 1 <= doc["o"] <= 1_000_000
                or type(doc["d"]) is not int
                or not doc["s"] <= doc["d"] <= MAX_SAFE_MS
                or not isinstance(doc["i"], str)
                or not pigi_oneshot.MESSAGE_ID.fullmatch(doc["i"])):
            raise ValueError
        return doc
    except (ValueError, TypeError, UnicodeEncodeError):
        raise argparse.ArgumentTypeError("invalid cursor") from None


def build_parser():
    parser = pigi_oneshot.Parser(prog="pigi-oneshot full", allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("accounts", allow_abbrev=False)
    listing = commands.add_parser(LIST_COMMAND, allow_abbrev=False)
    listing_paged = listing.add_mutually_exclusive_group()
    listing_paged.add_argument(
        "--since-days", type=pigi_oneshot.bounded_int(1, 30), default=7)
    listing_paged.add_argument("--history", action="store_true")
    listing_paged.add_argument("--cursor", type=cursor)
    listing.add_argument("--limit", type=pigi_oneshot.bounded_int(1, 20), default=10)
    search = commands.add_parser("search", allow_abbrev=False)
    search.add_argument("--query", required=True, type=query_text)
    search_paged = search.add_mutually_exclusive_group()
    search_paged.add_argument(
        "--since-days", type=pigi_oneshot.bounded_int(1, 30), default=7)
    search_paged.add_argument("--history", action="store_true")
    search_paged.add_argument("--cursor", type=cursor)
    search.add_argument("--limit", type=pigi_oneshot.bounded_int(1, 20), default=10)
    codes = commands.add_parser(CODES_COMMAND, allow_abbrev=False)
    codes.add_argument("--since-minutes", type=pigi_oneshot.bounded_int(
        1, CODES_SINCE_MAX_MINUTES), default=CODES_SINCE_DEFAULT_MINUTES)
    codes.add_argument("--limit", type=pigi_oneshot.bounded_int(1, 20), default=10)
    codes.add_argument("--offset", type=pigi_oneshot.bounded_int(
        0, CODES_OFFSET_MAX), default=0)
    codes.add_argument("--status", choices=CODES_STATUSES)
    codes.add_argument("--from-email", dest="from_email", action="append",
                       type=sender_filter)
    return parser


def parse_args(argv):
    args = pigi_oneshot.id_command(argv)
    if args is not None:
        return args
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command in (LIST_COMMAND, "search"):
        repeated = sum(a == "--cursor" or a.startswith("--cursor=")
                       for a in argv)
        if argv.count("--history") > 1 or repeated > 1:
            parser.error()
        if args.cursor is not None:
            expected = ("" if args.command == LIST_COMMAND
                        else query_digest(args.query))
            if (args.cursor["c"] != args.command
                    or args.cursor["q"] != expected):
                parser.error()
    if (args.command == CODES_COMMAND
            and len(args.from_email or ()) > CODES_MAX_SENDERS):
        parser.error()
    return args


def window(args, ctx):
    return {"since": ctx.now_ms() - args.since_days * 86_400_000, "limit": args.limit}


def own_record(record, ctx):
    return isinstance(record, dict) and record.get("account") == ctx.account


def own_items(items, ctx):
    return isinstance(items, list) and all(own_record(item, ctx) for item in items)


def row_key(item):
    return (-item["date"], item["messageID"])


def paged_rows(items, ctx):
    """Rows safe to page over: own account, typed key fields, strict order."""
    if not own_items(items, ctx):
        return False
    if any(type(item.get("date")) is not int
           or not isinstance(item.get("messageID"), str) for item in items):
        return False
    return all(row_key(a) < row_key(b)
               for a, b in zip(items, items[1:]))


def next_cursor(args, since, offset, item):
    doc = {"v": 1, "c": args.command,
           "q": "" if args.command == LIST_COMMAND else query_digest(args.query),
           "s": since, "o": offset, "d": item["date"], "i": item["messageID"]}
    raw = pigi_oneshot.json.dumps(doc, ensure_ascii=True,
                                  separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def anchor_safe(since, offset, item):
    """True when item can anchor a cursor this tool's own parser accepts."""
    return (since <= item["date"] <= MAX_SAFE_MS and offset <= 1_000_000
            and pigi_oneshot.MESSAGE_ID.fullmatch(item["messageID"])
            is not None)


def cut_item(item, budget):
    """Copy of item with each non-identity str field capped at budget chars."""
    cut, fields = dict(item), []
    for key, value in item.items():
        if (key in IDENTITY_FIELDS or not isinstance(value, str)
                or len(value) <= budget):
            continue
        cut[key] = value[:budget]
        fields.append(key)
    if fields:
        cut["truncatedFields"] = sorted(fields)
    return cut


def cut_get_metadata(payload, command):
    """Copy of a get/get-batch payload with each message's non-identity str
    fields capped at META_BUDGET, so emit can still fit identity + text."""
    if command == "get" and isinstance(payload.get("message"), dict):
        return dict(payload, message=cut_item(payload["message"], META_BUDGET))
    if command == "get-batch" and isinstance(payload.get("results"), list):
        return dict(payload, results=[
            dict(entry, message=cut_item(entry["message"], META_BUDGET))
            if (entry.get("status") == "ok"
                and isinstance(entry.get("message"), dict))
            else entry
            for entry in payload["results"]])
    return None


def cut_single_item(payload, item):
    """One item too big for a page: cut its non-identity str fields to a
    common budget so the message is delivered (never skipped)."""
    original = len(pigi_oneshot.serialize(payload))
    longest = max((len(value) for key, value in item.items()
                   if key not in IDENTITY_FIELDS and isinstance(value, str)),
                  default=0)

    def at_budget(budget):
        return dict(payload, items=[cut_item(item, budget)], truncated=True,
                    truncationNotice=pigi_oneshot.TRUNCATION_NOTICE,
                    originalBytes=original)

    low, high = 0, longest
    while low < high:
        middle = (low + high + 1) // 2
        if len(pigi_oneshot.serialize(at_budget(middle))) <= pigi_oneshot.MAX_STDOUT:
            low = middle
        else:
            high = middle - 1
    cut_payload = at_budget(low)
    if len(pigi_oneshot.serialize(cut_payload)) > pigi_oneshot.MAX_STDOUT:
        return pigi_oneshot.EXIT_UPSTREAM, \
            pigi_oneshot.upstream_failure("page_item_too_large")
    return pigi_oneshot.EXIT_TRUNCATED, cut_payload


def code_rows_valid(rows, ctx, since, floor, seen):
    """App code rows safe to filter and page over: own account, typed fields,
    fetchable messageID, inside the window, dates never increasing and no
    messageID repeated across the whole walk (a shifted page would repeat)."""
    previous = floor
    for row in rows:
        if (not own_record(row, ctx) or set(row) - set(CODES_FIELDS)
                or not isinstance(row.get("code"), str)
                or not isinstance(row.get("messageID"), str)
                or not pigi_oneshot.MESSAGE_ID.fullmatch(row["messageID"])
                or row["messageID"] in seen
                or type(row.get("date")) is not int or row["date"] < since
                or (previous is not None and row["date"] > previous)
                or any(key in row and not isinstance(row[key], str)
                       for key in ("fromName", "fromEmail"))):
            return False
        seen.add(row["messageID"])
        previous = row["date"]
    return True


def sender_matches(row, senders):
    sender = row.get("fromEmail")
    return isinstance(sender, str) and sender.strip().lower() in senders


def command_codes(args, ctx):
    """Cached verification codes: App time window, oneshot sender filter.

    The App cannot filter by sender, so this walks the App's pages (at most
    CODES_MAX_FETCHES) until offset + limit + 1 rows match or the App has no
    further page. limit/offset/nextOffset all refer to the filtered list. If
    the walk cannot reach a decision within the fetch cap it fails: it never
    reports a possibly incomplete result as complete.
    """
    since = ctx.now_ms() - args.since_minutes * 60_000
    senders = frozenset(args.from_email or ())
    needed = args.offset + args.limit + 1
    matched, seen, app_offset, floor, fetches = [], set(), 0, None, 0
    while True:
        if fetches >= CODES_MAX_FETCHES:
            return pigi_oneshot.EXIT_UPSTREAM, \
                pigi_oneshot.upstream_failure("page_limit_exceeded")
        fetches += 1
        params = {"account": ctx.account, "since": since,
                  "limit": CODES_FETCH, "offset": app_offset}
        if args.status is not None:
            params["status"] = args.status
        status, value = pigi_oneshot.single_call(
            ctx, CODES_TOOL, params, enable_codes=True)
        if status == "error":
            return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure(value)
        rows, later = value.get("codes"), value.get("nextOffset")
        if not isinstance(rows, list) or not code_rows_valid(rows, ctx, since, floor, seen):
            return pigi_oneshot.EXIT_UPSTREAM, \
                pigi_oneshot.upstream_failure("invalid_response")
        if rows:
            floor = rows[-1]["date"]
        matched.extend(row for row in rows
                       if not senders or sender_matches(row, senders))
        # Validate every page's nextOffset before any early exit: a bad one
        # fails the run even when this page already completed the result.
        if later is not None and (
                type(later) is not int or not rows
                or later != app_offset + len(rows) or later > CODES_OFFSET_MAX):
            return pigi_oneshot.EXIT_UPSTREAM, \
                pigi_oneshot.upstream_failure("invalid_response")
        if later is None or len(matched) >= needed:
            break
        app_offset = later
    page = matched[args.offset:args.offset + args.limit]
    body = {"codes": [{key: row[key] for key in CODES_FIELDS if key in row}
                      for row in page]}
    if len(matched) > args.offset + args.limit:
        body["nextOffset"] = args.offset + len(page)
    # Oversize output is not shortened here: emit_full applies the standard
    # truncation (truncated:true, no codes, exit 8), never a complete success.
    return pigi_oneshot.EXIT_OK, pigi_oneshot.envelope(CODES_COMMAND, body)


def command_accounts(args, ctx):
    status, value = pigi_oneshot.single_call(ctx, "list_accounts", {})
    if status == "error":
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure(value)
    accounts = value.get("accounts")
    if not own_items(accounts, ctx):
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure("invalid_response")
    return pigi_oneshot.EXIT_OK, pigi_oneshot.envelope("accounts", {"accounts": accounts})


def command_page(args, ctx):
    """One upstream window per page, keyset-anchored to avoid dup/gap."""
    if args.cursor is None:
        since = ctx.now_ms() - HISTORY_MAX_DAYS * 86_400_000
        offset, anchor = 0, None
    else:
        since = args.cursor["s"]
        offset = max(0, args.cursor["o"] - BACK)
        anchor = (-args.cursor["d"], args.cursor["i"])
    params = {"account": ctx.account, "since": since,
              "limit": WINDOW, "offset": offset}
    tool = LIST_TOOL
    if args.command == "search":
        tool, params["query"] = "search", args.query
    status, value = pigi_oneshot.single_call(ctx, tool, params)
    if status == "error":
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure(value)
    rows, later = value.get("items"), value.get("nextOffset")
    if not paged_rows(rows, ctx):
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure("invalid_response")
    if (anchor is not None and offset > 0
            and (not rows or row_key(rows[0]) > anchor)):
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure("cursor_stale")
    start = 0 if anchor is None else next(
        (index for index, row in enumerate(rows) if row_key(row) > anchor),
        len(rows))
    remaining = rows[start:]
    if not remaining and later is not None:
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure("cursor_stale")
    take = remaining[:args.limit]
    # Every item a page would deliver must be fetchable via `get`: an id that
    # fails the single MESSAGE_ID contract closes the walk, never a skip.
    if not all(pigi_oneshot.MESSAGE_ID.fullmatch(item["messageID"])
               for item in take):
        return pigi_oneshot.EXIT_UPSTREAM, \
            pigi_oneshot.upstream_failure("invalid_response")
    # A page must not drop items the cursor then skips: emit a shorter prefix
    # instead of the usual shrink. One item that still does not fit is
    # delivered with its non-identity text fields cut (exit 8), never skipped.
    n = len(take)
    while True:
        cut = take[:n]
        more = len(remaining) > n or later is not None
        if more and cut and not anchor_safe(since, offset + start + n, cut[-1]):
            return pigi_oneshot.EXIT_UPSTREAM, \
                pigi_oneshot.upstream_failure("invalid_response")
        token = (next_cursor(args, since, offset + start + n, cut[-1])
                 if more and cut else None)
        payload = pigi_oneshot.envelope(args.command, {
            "items": cut, "page": {"end": not more, "nextCursor": token}})
        if len(pigi_oneshot.serialize(payload)) <= pigi_oneshot.MAX_STDOUT:
            return pigi_oneshot.EXIT_OK, payload
        if n <= 1:
            return cut_single_item(payload, take[0])
        n -= 1


def command_list(args, ctx):
    if args.history or args.cursor is not None:
        return command_page(args, ctx)
    status, value = pigi_oneshot.single_call(ctx, LIST_TOOL, window(args, ctx))
    if status == "error":
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure(value)
    items = value.get("items")
    if not own_items(items, ctx):
        return pigi_oneshot.EXIT_UPSTREAM, pigi_oneshot.upstream_failure("invalid_response")
    return pigi_oneshot.EXIT_OK, pigi_oneshot.envelope(LIST_COMMAND, {"items": items})


def command_search(args, ctx):
    if args.history or args.cursor is not None:
        return command_page(args, ctx)
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
    out, truncated = pigi_oneshot.emit(payload)
    if not truncated or command not in {"get", "get-batch"}:
        return out, truncated
    data_key = "message" if command == "get" else "results"
    if data_key in pigi_oneshot.json.loads(out):
        return out, truncated
    # Message metadata alone overflowed the cap: cut it to META_BUDGET so
    # emit can still deliver identity + text, then keep originalBytes honest
    # (the serialized size of the uncut payload).
    cut = cut_get_metadata(payload, command)
    if cut is None:
        return out, truncated
    cut_out, _ = pigi_oneshot.emit(cut)
    doc = pigi_oneshot.json.loads(cut_out)
    if data_key not in doc:
        return out, truncated
    doc["truncated"] = True
    doc["truncationNotice"] = pigi_oneshot.TRUNCATION_NOTICE
    doc["originalBytes"] = len(body)
    cut_out = pigi_oneshot.serialize(doc)
    if len(cut_out) <= pigi_oneshot.MAX_STDOUT:
        return cut_out, True
    return out, truncated


def run_command(args, ctx):
    if getattr(ctx, "profile", None) != pigi_oneshot.PROFILE_FULL:
        return pigi_oneshot.EXIT_USAGE, pigi_oneshot.USAGE_ERROR_JSON.encode("ascii")
    parsed = getattr(args, "cursor", None)
    if parsed is not None:
        # A cursor is bound to the horizon minted by --history: it stays
        # valid for CURSOR_TTL_MS (plus CLOCK_SKEW_MS for clock drift).
        horizon = ctx.now_ms() - HISTORY_MAX_DAYS * 86_400_000
        if not (horizon - CURSOR_TTL_MS <= parsed["s"]
                <= horizon + CLOCK_SKEW_MS):
            return pigi_oneshot.EXIT_USAGE, pigi_oneshot.USAGE_ERROR_JSON.encode("ascii")
    try:
        if args.command == "accounts":
            code, payload = command_accounts(args, ctx)
        elif args.command == LIST_COMMAND:
            code, payload = command_list(args, ctx)
        elif args.command == "search":
            code, payload = command_search(args, ctx)
        elif args.command == CODES_COMMAND:
            code, payload = command_codes(args, ctx)
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
