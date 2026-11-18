"""Synthetic fixtures only: fake agent.sock in a short temp dir, never real mail or HOME."""
import contextlib
import io
import json
import os
from pathlib import Path
import pwd
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

import audit
import pigi_oneshot
from pigi_mcp import TRUST_NOTICE
import transport

SCRIPT = Path(__file__).with_name("pigi_oneshot.py")
DOCS = Path(__file__).resolve().parent.parent.parent / "docs" / "pigi-oneshot.md"
ORIGINAL_PINNED_HOME = pigi_oneshot.PINNED_HOME
ACCOUNT = "target@example.com"
ALLOWED = "allowed@example.com"
OTHER = "other@example.org"
NOW = 1_800_000_000_000
CAPS = ["filters", "scoped_accounts"]
SENTINEL = "BODY_SENTINEL_DO_NOT_LEAK"
FIXED_ERROR_CODES = {"invalid_request", "unsupported_version", "method_not_found", "not_found",
                     "unauthorized", "permission_denied", "audit_unavailable", "too_large",
                     "timeout", "internal_error", "unavailable", "unsupported_server",
                     "invalid_response", "upstream_unavailable"}
USAGE_DOC = {"contentTrust": "untrusted", "error": "invalid_arguments"}
CONFIG_DOC = {"contentTrust": "untrusted", "error": "configuration_unavailable"}
INTERNAL_DOC = {"contentTrust": "untrusted", "error": "internal_error"}


def real_homes():
    return {os.path.realpath(os.path.expanduser("~")),
            os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir),
            os.path.realpath(ORIGINAL_PINNED_HOME)}


def assert_isolated(home, config_path, socket_path, audit_db):
    """Refuse (AssertionError) when any path resolves to a real location."""
    homes = real_homes()
    resolved_home = os.path.realpath(home)
    if resolved_home in homes:
        raise AssertionError("refusing to run against real home: %s" % resolved_home)
    protected = []
    for real in homes:
        base = os.path.join(real, "Library", "Application Support")
        protected += [os.path.join(base, "pigi"), os.path.join(base, "pigi-mcp")]
    for label, path in (("config", config_path), ("socket", socket_path),
                        ("audit", audit_db)):
        resolved = os.path.realpath(path)
        for root in protected:
            if resolved == root or resolved.startswith(root + os.sep):
                raise AssertionError("refusing real %s path: %s" % (label, resolved))
    if os.path.realpath(socket_path) == os.path.realpath(transport.DEFAULT_SOCKET):
        raise AssertionError("refusing default socket path")
    if os.path.realpath(audit_db) == os.path.realpath(audit.DEFAULT_AUDIT):
        raise AssertionError("refusing default audit path")


def setUpModule():
    # Prove the guard is wired: the production defaults must trip it. Every
    # fixture below injects temp paths — the suite never uses real defaults.
    default_config = Path(ORIGINAL_PINNED_HOME).joinpath(*pigi_oneshot.CONFIG_PARTS)
    try:
        assert_isolated(ORIGINAL_PINNED_HOME, default_config,
                        transport.DEFAULT_SOCKET, audit.DEFAULT_AUDIT)
    except AssertionError:
        pass
    else:
        raise AssertionError("isolation guard ignored real defaults")


class _BytesStdout:
    """Stand-in for sys.stdout exposing .buffer and text write()."""

    def __init__(self):
        self.buffer = io.BytesIO()

    def write(self, text):
        self.buffer.write(str(text).encode("utf-8"))

    def flush(self):
        pass


def make_message(message_id, sender=ALLOWED, **fields):
    message = {"account": ACCOUNT, "messageID": message_id, "date": NOW,
               "subject": "synthetic subject", "fromName": "Synthetic Sender",
               "fromEmail": sender, "snippet": "synthetic snippet",
               "unread": False, "starred": False, "status": "inbox"}
    message.update(fields)
    return message


def accounts_result():
    return {"accounts": [{"account": ACCOUNT, "kind": "imap"}],
            "contentTrust": "untrusted", "capabilities": CAPS}


def search_result(items):
    return {"items": items, "contentTrust": "untrusted", "capabilities": CAPS}


def get_result(message, text):
    return {"message": message, "text": text,
            "contentTrust": "untrusted", "capabilities": CAPS}


class AgentError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def agent_handler(table):
    def handle(request):
        responder = table.get(request.get("method"))
        if responder is None:
            return {"version": 1, "id": request["id"],
                    "error": {"code": "method_not_found", "message": "method_not_found"}}
        try:
            result = responder(request.get("params") or {})
        except AgentError as error:
            return {"version": 1, "id": request["id"],
                    "error": {"code": error.code, "message": error.code}}
        return {"version": 1, "id": request["id"], "result": result}
    return handle


class FakeAgent(threading.Thread):
    """Protocol-v1 responder on a private socket; records every request frame."""

    def __init__(self, directory, table):
        super().__init__(daemon=True)
        self.endpoint = os.path.join(directory, "agent.sock")
        self.table = table
        self.requests = []
        self.errors = []
        self.ready = threading.Event()
        self.halt = threading.Event()

    def run(self):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.endpoint)
        os.chmod(self.endpoint, 0o600)
        listener.listen(8)
        listener.settimeout(0.2)
        self.ready.set()
        try:
            while not self.halt.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    try:
                        connection.settimeout(5)
                        data = b""
                        while not data.endswith(b"\n"):
                            chunk = connection.recv(65536)
                            if not chunk:
                                break
                            data += chunk
                        request = json.loads(data)
                        self.requests.append(request)
                        response = agent_handler(self.table)(request)
                        connection.sendall(json.dumps(response).encode("utf-8") + b"\n")
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    except Exception as error:
                        self.errors.append(error)
        finally:
            listener.close()

    def stop(self):
        self.halt.set()
        self.join(4)


class OneshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="po-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        os.chmod(self.temp.name, 0o700)
        self.root = Path(self.temp.name)
        self.table = {}
        self.agent = FakeAgent(self.temp.name, self.table)
        self.agent.start()
        self.assertTrue(self.agent.ready.wait(3))
        self.addCleanup(self.stop_agent)
        self.ctx = pigi_oneshot.Context(
            ACCOUNT, {ALLOWED}, socket_path=self.agent.endpoint,
            audit_db=self.root / "audit.sqlite3", python=sys.executable,
            home=self.temp.name, now_ms=lambda: NOW)
        assert_isolated(self.temp.name, self.root / "oneshot.json",
                        self.ctx.socket_path, self.ctx.audit_db)

    def stop_agent(self):
        self.agent.stop()
        self.assertFalse(self.agent.is_alive())
        self.assertEqual(self.agent.errors, [])

    def invoke(self, argv, ctx=None):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code, out = pigi_oneshot.execute(argv, ctx or self.ctx)
        self.assertEqual(err.getvalue(), "")
        return code, out

    def parse(self, out):
        return json.loads(out.decode("utf-8").strip())

    def cli(self, args):
        result = subprocess.run(
            [sys.executable, "-B", "-E", "-S", "-X", "utf8", str(SCRIPT), *args],
            capture_output=True, timeout=20,
            env={"HOME": self.temp.name, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
        self.assertEqual(result.stderr, b"")
        if result.stdout:
            json.loads(result.stdout)  # always a single JSON document
        return result

    def make_home(self, name, config=None, agent=False):
        """Isolated fake HOME, optionally with a valid config and a live fake
        socket at the production-derived path inside it."""
        home = self.root / name
        appdir = home / "Library" / "Application Support" / "pigi"
        appdir.mkdir(parents=True)
        os.chmod(appdir, 0o700)
        if config is not None:
            path = appdir / "oneshot.json"
            path.write_text(json.dumps(config))
            os.chmod(path, 0o600)
        listener = None
        if agent:
            listener = FakeAgent(str(appdir), self.table)
            listener.start()
            self.assertTrue(listener.ready.wait(3))
            self.addCleanup(listener.stop)
        return home, listener

    def invoke_main(self, argv, home, patches=()):
        """Run main() with PINNED_HOME patched to an isolated home; returns
        (exit_code, stdout_bytes, parsed_doc). Asserts stderr stays empty."""
        support = Path(home) / "Library" / "Application Support"
        assert_isolated(str(home), support / "pigi" / "oneshot.json",
                        support / "pigi" / "agent.sock",
                        support / "pigi-mcp" / "audit.sqlite3")
        stdout, err = _BytesStdout(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(pigi_oneshot, "PINNED_HOME", str(home)))
            stack.enter_context(patch.object(pigi_oneshot, "is_hardened", lambda: True))
            stack.enter_context(patch.object(sys, "argv", ["pigi-oneshot", *argv]))
            stack.enter_context(patch.object(sys, "stdout", stdout))
            stack.enter_context(contextlib.redirect_stderr(err))
            for extra in patches:
                stack.enter_context(extra)
            code = pigi_oneshot.main()
        self.assertEqual(err.getvalue(), "")
        out = stdout.buffer.getvalue()
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        return code, out, json.loads(out) if out else None

    def audit_rows(self):
        with sqlite3.connect(self.root / "audit.sqlite3") as db:
            return db.execute("SELECT tool,outcome FROM tool_calls ORDER BY id").fetchall()

    def methods_seen(self):
        return [request["method"] for request in self.agent.requests]

    def test_accounts_scoped_result(self):
        self.table["accounts"] = lambda params: accounts_result()
        code, out = self.invoke(["accounts"])
        self.assertEqual(code, 0)
        doc = self.parse(out)
        self.assertEqual(doc["contentTrust"], "untrusted")
        self.assertEqual(doc["trustNotice"], TRUST_NOTICE)
        self.assertEqual(doc["command"], "accounts")
        self.assertEqual(doc["accounts"], [{"account": ACCOUNT, "kind": "imap"}])
        self.assertEqual(self.methods_seen(), ["accounts"])
        self.assertEqual(self.agent.requests[0]["params"], {"account": ACCOUNT})
        self.assertEqual(self.audit_rows(), [("list_accounts", "ok")])

    def test_search_argument_rejection_never_touches_socket(self):
        rejected = [["search", "--query", "x"], ["search", "x"],
                    ["search", "--since-days", "31"], ["search", "--since-days", "0"],
                    ["search", "--since-days", "x"], ["search", "--limit", "21"],
                    ["search", "--limit", "0"], ["search", "--offset", "1"],
                    ["search", "--offset=0"], ["search", "--lim", "5"],
                    ["search", "--since", "3"], ["search", "--account", "x"]]
        for argv in rejected:
            with self.subTest(argv=argv):
                code, out = self.invoke(argv)
                self.assertEqual(code, 2)
                self.assertEqual(self.parse(out), USAGE_DOC)
                result = self.cli(argv)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertEqual(self.agent.requests, [])

    def test_search_scopes_filters_and_reports_filtered_out(self):
        items = [make_message("m1", ALLOWED), make_message("m2", OTHER),
                 make_message("m3", ALLOWED)]
        self.table["search"] = lambda params: {**search_result(items), "nextOffset": 3}
        code, out = self.invoke(["search"])
        self.assertEqual(code, 0)
        doc = self.parse(out)
        self.assertEqual(doc["command"], "search")
        self.assertEqual([item["messageID"] for item in doc["items"]], ["m1", "m3"])
        self.assertEqual(doc["filteredOut"], 1)
        self.assertNotIn("nextOffset", doc)
        request = self.agent.requests[0]
        self.assertEqual(request["method"], "search")
        self.assertEqual(request["params"], {"account": ACCOUNT, "query": "Cursor",
                                             "since": NOW - 7 * 86_400_000, "limit": 10})
        self.assertNotIn(OTHER, out.decode("utf-8"))

    def test_search_bounds(self):
        self.table["search"] = lambda params: search_result([])
        code, out = self.invoke(["search", "--since-days", "30", "--limit", "20"])
        self.assertEqual(code, 0)
        self.assertEqual(self.agent.requests[0]["params"]["since"], NOW - 30 * 86_400_000)
        self.assertEqual(self.agent.requests[0]["params"]["limit"], 20)

    def test_get_allowed_sender_returns_text(self):
        self.table["get"] = lambda params: get_result(make_message("m1"), SENTINEL)
        code, out = self.invoke(["get", "m1"])
        self.assertEqual(code, 0)
        doc = self.parse(out)
        self.assertEqual(doc["command"], "get")
        self.assertEqual(doc["text"], SENTINEL)
        self.assertEqual(doc["message"]["messageID"], "m1")
        request = self.agent.requests[0]
        self.assertEqual(request["method"], "get")
        self.assertEqual(request["params"], {"account": ACCOUNT, "messageID": "m1"})

    def test_get_disallowed_sender_built_from_scratch(self):
        self.table["get"] = lambda params: get_result(
            make_message("m2", OTHER, subject="SUBJ_SENTINEL", snippet="SNIP_SENTINEL"),
            SENTINEL)
        code, out = self.invoke(["get", "m2"])
        self.assertEqual(code, 3)
        doc = self.parse(out)
        self.assertEqual(doc, {"contentTrust": "untrusted", "trustNotice": TRUST_NOTICE,
                               "allowed": False, "message": None})
        text = out.decode("utf-8")
        for leak in (SENTINEL, "SUBJ_SENTINEL", "SNIP_SENTINEL", OTHER):
            self.assertNotIn(leak, text)
        self.assertEqual(self.methods_seen(), ["get"])

    def test_get_sender_case_insensitive_match(self):
        self.table["get"] = lambda params: get_result(
            make_message("m3", "Allowed@Example.COM"), "body")
        code, out = self.invoke(["get", "m3"])
        self.assertEqual(code, 0)
        self.assertEqual(self.parse(out)["message"]["fromEmail"], "Allowed@Example.COM")

    def test_get_not_found(self):
        def responder(params):
            raise AgentError("not_found")
        self.table["get"] = responder
        code, out = self.invoke(["get", "m9"])
        self.assertEqual(code, 4)
        doc = self.parse(out)
        self.assertEqual(doc, {"contentTrust": "untrusted", "error": "not_found"})

    def test_get_invalid_ids_rejected_without_socket(self):
        for bad in ("has space", "a/b", "a<b", "a$b", "", "x" * 257):
            with self.subTest(bad=bad):
                code, out = self.invoke(["get", bad])
                self.assertEqual(code, 2)
                self.assertEqual(self.parse(out), USAGE_DOC)
        for argv in (["get", "-abc"], ["get"], ["get", "ok", "extra"]):
            result = self.cli(argv)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertEqual(self.agent.requests, [])

    def test_get_batch_mixed_statuses_and_precedence(self):
        def responder(params):
            message_id = params["messageID"]
            if message_id == "gone":
                raise AgentError("not_found")
            if message_id == "boom":
                raise AgentError("timeout")
            if message_id == "deny":
                return get_result(make_message(message_id, OTHER), SENTINEL)
            return get_result(make_message(message_id), "body-" + message_id)
        self.table["get"] = responder
        code, out = self.invoke(["get-batch", "a", "deny", "gone", "boom", "b"])
        self.assertEqual(code, 5)
        doc = self.parse(out)
        self.assertEqual(doc["command"], "get-batch")
        statuses = [entry["status"] for entry in doc["results"]]
        self.assertEqual(statuses, ["ok", "filtered", "not_found", "error", "ok"])
        filtered = doc["results"][1]
        self.assertEqual(filtered, {"messageID": "deny", "status": "filtered"})
        self.assertEqual(doc["results"][3],
                         {"messageID": "boom", "status": "error", "error": "timeout"})
        self.assertNotIn(SENTINEL, out.decode("utf-8"))
        # One child, one handshake: five socket requests, five audit rows.
        self.assertEqual(self.methods_seen(), ["get"] * 5)
        self.assertEqual([row[0] for row in self.audit_rows()], ["get_message"] * 5)

    def test_get_batch_exit_code_precedence(self):
        def responder(params):
            message_id = params["messageID"]
            if message_id == "gone":
                raise AgentError("not_found")
            if message_id == "deny":
                return get_result(make_message(message_id, OTHER), SENTINEL)
            return get_result(make_message(message_id), "body")
        self.table["get"] = responder
        self.assertEqual(self.invoke(["get-batch", "a", "deny", "gone"])[0], 4)
        self.assertEqual(self.invoke(["get-batch", "a", "deny"])[0], 3)
        self.assertEqual(self.invoke(["get-batch", "a"])[0], 0)

    def test_get_batch_size_rejected_without_socket(self):
        for argv in (["get-batch"] + ["m%d" % i for i in range(6)], ["get-batch"]):
            code, out = self.invoke(argv)
            self.assertEqual(code, 2)
            self.assertEqual(self.parse(out), USAGE_DOC)
        result = self.cli(["get-batch"] + ["m%d" % i for i in range(6)])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.agent.requests, [])

    def test_unimplemented_and_scope_options_rejected(self):
        rejected = [["list"], ["get_verification_code"], ["unknown"], [],
                    ["--help"], ["-h"], ["accounts", "--help"], ["search", "-h"],
                    ["--account", "x", "accounts"], ["accounts", "--account", "x"],
                    ["--account=x", "accounts"], ["search", "extra"]]
        for argv in rejected:
            with self.subTest(argv=argv):
                code, out = self.invoke(argv)
                self.assertEqual(code, 2)
                self.assertEqual(self.parse(out), USAGE_DOC)
                result = self.cli(argv)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        self.assertEqual(self.agent.requests, [])
        source = SCRIPT.read_text()
        for forbidden in ('"list"', '"codes"', "get_verification_code", "list_messages"):
            self.assertNotIn(forbidden, source)

    def test_search_truncation_stays_valid_json_exit_eight(self):
        big = [make_message("m%d" % i, ALLOWED, snippet="A" * 30_000) for i in range(3)]
        self.table["search"] = lambda params: search_result(big)
        code, out = self.invoke(["search", "--limit", "20"])
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        doc = self.parse(out)  # json.loads must succeed: always valid JSON
        self.assertTrue(doc["truncated"])
        self.assertEqual(doc["contentTrust"], "untrusted")
        self.assertEqual(doc["command"], "search")
        self.assertEqual(len(doc["items"]) + doc["omittedItems"], 3)
        self.assertGreater(doc["omittedItems"], 0)
        self.assertEqual(doc["filteredOut"], 0)

    def test_get_truncation_multibyte_text_exit_eight(self):
        message = make_message("m1")
        text = "中文字符正文🎉trailer" * 6_000
        self.table["get"] = lambda params: get_result(message, text)
        code, out = self.invoke(["get", "m1"])
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        doc = self.parse(out)
        self.assertTrue(doc["truncated"])
        self.assertTrue(doc["textTruncated"])
        self.assertEqual(doc["message"]["messageID"], "m1")
        self.assertLess(len(doc["text"]), len(text))
        full = pigi_oneshot.envelope("get", {"message": message, "text": text})
        self.assertEqual(doc["originalBytes"], len(pigi_oneshot.serialize(full)))

    def test_get_batch_truncation_cuts_every_text(self):
        texts = {"m%d" % i: "B" * 30_000 + str(i) for i in range(5)}
        self.table["get"] = lambda params: get_result(
            make_message(params["messageID"]), texts[params["messageID"]])
        code, out = self.invoke(["get-batch"] + list(texts))
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        doc = self.parse(out)
        self.assertTrue(doc["truncated"])
        self.assertEqual(len(doc["results"]), 5)
        for entry in doc["results"]:
            self.assertEqual(entry["status"], "ok")
            self.assertTrue(entry["textTruncated"])

    def test_get_batch_truncation_keeps_denial_exit_three(self):
        def responder(params):
            message_id = params["messageID"]
            if message_id == "deny":
                return get_result(make_message(message_id, OTHER), SENTINEL)
            return get_result(make_message(message_id), "B" * 40_000)
        self.table["get"] = responder
        code, out = self.invoke(["get-batch", "a", "deny", "c"])
        self.assertEqual(code, 3)  # already non-zero: truncation does not lift it to 8
        doc = self.parse(out)
        self.assertTrue(doc["truncated"])
        self.assertEqual(doc["results"][1], {"messageID": "deny", "status": "filtered"})
        self.assertNotIn(SENTINEL, out.decode("utf-8"))

    def test_truncation_fallback_when_metadata_alone_huge(self):
        giant = make_message("m1", subject="S" * 200_000)
        self.table["get"] = lambda params: get_result(giant, SENTINEL)
        code, out = self.invoke(["get", "m1"])
        self.assertEqual(code, 8)
        doc = self.parse(out)
        self.assertEqual(set(doc), {"contentTrust", "trustNotice", "command",
                                    "truncated", "truncationNotice", "originalBytes"})
        self.assertEqual(doc["command"], "get")
        self.assertTrue(doc["truncated"])
        for leak in (SENTINEL, "S" * 100):
            self.assertNotIn(leak, out.decode("utf-8"))

    def test_serialized_boundary_exactly_max_stdout(self):
        message = make_message("m1")
        overhead = len(pigi_oneshot.serialize(
            pigi_oneshot.envelope("get", {"message": message, "text": ""})))
        self.table["get"] = lambda params: get_result(
            message, "x" * (pigi_oneshot.MAX_STDOUT - overhead))
        code, out = self.invoke(["get", "m1"])
        self.assertEqual((code, len(out)), (0, pigi_oneshot.MAX_STDOUT))
        self.assertNotIn("truncated", self.parse(out))
        self.table["get"] = lambda params: get_result(
            message, "x" * (pigi_oneshot.MAX_STDOUT + 1 - overhead))
        code, out = self.invoke(["get", "m1"])
        self.assertEqual(code, 8)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        self.assertTrue(self.parse(out)["truncated"])

    def test_preamble_gate_precedes_environment_imports(self):
        import ast
        tree = ast.parse(SCRIPT.read_text())
        gate = None
        for node in tree.body:
            if (isinstance(node, ast.If) and isinstance(node.test, ast.BoolOp)
                    and any(isinstance(part, ast.Compare)
                            and isinstance(part.left, ast.Name)
                            and part.left.id == "__name__" for part in node.test.values)):
                gate = node
                break
        self.assertIsNotNone(gate, "missing __main__ hardening gate")
        before = tree.body[:tree.body.index(gate)]
        defined = {node.name for node in before if isinstance(node, ast.FunctionDef)}
        self.assertIn("is_hardened", defined)
        self.assertIn("hardened_exec_args", defined)
        for node in before:
            if isinstance(node, ast.Import):
                for alias in node.names:
                    self.assertIn(alias.name, {"os", "sys"})
            elif isinstance(node, ast.ImportFrom):
                self.fail("module import before hardening gate: %s" % node.module)
        self.assertTrue(any(isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                            and n.func.attr == "execve" for n in ast.walk(gate)))

    def test_unhardened_start_never_imports_environment_modules(self):
        rogue = self.root / "rogue-site"
        rogue.mkdir()
        canary = self.root / "canary"
        for name in ("json.py", "argparse.py"):
            (rogue / name).write_text(
                "import pathlib\npathlib.Path(%r).write_text('hit')\n"
                "raise SystemExit(88)\n" % str(canary))
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "list"],
            capture_output=True, timeout=20, cwd=self.temp.name,
            env={"HOME": self.temp.name, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                 "PYTHONPATH": str(rogue)})
        self.assertFalse(canary.exists())
        self.assertNotEqual(result.returncode, 88)
        # 2 when the pinned interpreter exists (hardened child rejects `list`),
        # 6 where it is absent; either way the rogue modules never ran.
        self.assertIn(result.returncode, {2, 6})
        self.assertEqual(result.stderr, b"")
        if result.returncode == 2:
            self.assertEqual(self.parse(result.stdout), USAGE_DOC)
        elif result.returncode == 6:
            self.assertEqual(self.parse(result.stdout), CONFIG_DOC)

    def test_get_batch_all_denied_exact_filtered_shape(self):
        self.table["get"] = lambda params: get_result(
            make_message(params["messageID"], OTHER, subject="SUBJ_SENTINEL",
                         snippet="SNIP_SENTINEL"), SENTINEL)
        code, out = self.invoke(["get-batch", "a", "b", "c"])
        self.assertEqual(code, 3)
        doc = self.parse(out)
        self.assertEqual(doc["results"], [{"messageID": mid, "status": "filtered"}
                                          for mid in ("a", "b", "c")])
        text = out.decode("utf-8")
        for leak in (SENTINEL, "SUBJ_SENTINEL", "SNIP_SENTINEL", OTHER):
            self.assertNotIn(leak, text)

    def test_get_writes_exactly_one_adapter_audit_row(self):
        self.table["get"] = lambda params: get_result(make_message("m1"), "body")
        code, out = self.invoke(["get", "m1"])
        self.assertEqual(code, 0)
        self.assertEqual(self.audit_rows(), [("get_message", "ok")])

    def test_docs_contract_matches_implementation(self):
        doc = DOCS.read_text()
        self.assertIn('"status":"filtered"', doc)
        self.assertNotIn("no write path", doc)
        self.assertIn("tool_calls", doc)
        self.assertIn("| 8 |", doc)
        self.assertIn("truncated", doc)
        self.assertIn('"error":"invalid_arguments"', doc)
        self.assertIn('"error":"configuration_unavailable"', doc)
        self.assertIn('"error":"internal_error"', doc)
        self.assertIn("stderr", doc)

    def test_config_loader_fails_closed(self):
        home = self.root / "cfg-home"
        config_dir = home / "Library" / "Application Support" / "pigi"
        config_path = config_dir / "oneshot.json"

        def expect_six():
            with self.assertRaises(pigi_oneshot.ConfigError):
                pigi_oneshot.load_config(str(home))

        expect_six()  # missing entirely
        config_dir.mkdir(parents=True, mode=0o700)
        config_path.write_text('{"account": "%s", "senders": ["%s"]}' % (ACCOUNT, ALLOWED))
        os.chmod(config_path, 0o644)
        expect_six()  # permissive mode
        os.chmod(config_path, 0o600)
        link = config_dir / "link.json"
        os.link(config_path, link)
        expect_six()  # hard link count != 1 — still fail closed via the real path
        link.unlink()
        # Symlink in place of the config file.
        config_path.unlink()
        config_path.symlink_to(home)
        expect_six()
        config_path.unlink()
        # Wrong shapes.
        for doc in [{}, {"account": ACCOUNT}, {"senders": [ALLOWED]},
                    {"account": ACCOUNT, "senders": []},
                    {"account": ACCOUNT, "senders": [ALLOWED], "extra": 1},
                    {"account": "  ", "senders": [ALLOWED]},
                    {"account": ACCOUNT, "senders": ["  "]},
                    {"account": ACCOUNT, "senders": "notalist"},
                    {"account": 5, "senders": [ALLOWED]},
                    {"account": "x" * 1025, "senders": [ALLOWED]}]:
            config_path.write_text(json.dumps(doc))
            os.chmod(config_path, 0o600)
            expect_six()
        config_path.write_text("not json")
        os.chmod(config_path, 0o600)
        expect_six()
        # Group/world-writable parent dir.
        os.chmod(config_dir, 0o777)
        expect_six()
        os.chmod(config_dir, 0o700)
        # Valid.
        config_path.write_text('{"account": "%s", "senders": [" %s ", "%s"]}'
                               % (ACCOUNT, ALLOWED.upper(), OTHER))
        os.chmod(config_path, 0o600)
        config = pigi_oneshot.load_config(str(home))
        self.assertEqual(config["account"], ACCOUNT)
        self.assertEqual(config["senders"], frozenset({ALLOWED, OTHER}))

    def test_hardening_helpers(self):
        self.assertFalse(pigi_oneshot.is_hardened())
        args = pigi_oneshot.hardened_exec_args(["prog", "search", "--limit", "3"])
        self.assertEqual(args, [pigi_oneshot.PINNED_PYTHON, "-B", "-E", "-S", "-X",
                                "utf8", os.path.realpath(pigi_oneshot.__file__),
                                "search", "--limit", "3"])
        self.assertEqual(pigi_oneshot.EXEC_ENV,
                         {"HOME": pigi_oneshot.PINNED_HOME,
                          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
        self.assertEqual(set(pigi_oneshot.EXEC_ENV), {"HOME", "PATH"})

    def test_transport_failures_exit_five_without_leaks(self):
        self.table["accounts"] = lambda params: accounts_result()
        missing = pigi_oneshot.Context(
            ACCOUNT, {ALLOWED}, socket_path=self.root / "missing.sock",
            audit_db=self.root / "a2.sqlite3", python=sys.executable,
            home=self.temp.name, now_ms=lambda: NOW)
        code, out = self.invoke(["accounts"], missing)
        self.assertEqual(code, 5)
        doc = self.parse(out)
        self.assertEqual(doc["contentTrust"], "untrusted")
        self.assertIn(doc["error"], FIXED_ERROR_CODES)
        # A regular file at the socket path yields the same fixed-shape error.
        regular = self.root / "not-a-socket"
        regular.write_text("keep")
        bad = pigi_oneshot.Context(
            ACCOUNT, {ALLOWED}, socket_path=regular, audit_db=self.root / "a3.sqlite3",
            python=sys.executable, home=self.temp.name, now_ms=lambda: NOW)
        code, out = self.invoke(["accounts"], bad)
        self.assertEqual(code, 5)
        self.assertNotIn(SENTINEL, out.decode("utf-8"))

    def test_internal_error_exit_seven(self):
        with patch.object(pigi_oneshot, "mcp_session", side_effect=RuntimeError("boom")):
            code, out = self.invoke(["accounts"])
        self.assertEqual(code, 7)
        self.assertEqual(self.parse(out), INTERNAL_DOC)

    def test_only_scoped_methods_ever_called(self):
        self.table["accounts"] = lambda params: accounts_result()
        self.table["search"] = lambda params: search_result([make_message("m1")])
        self.table["get"] = lambda params: get_result(make_message("m1"), "body")
        for argv in (["accounts"], ["search"], ["get", "m1"],
                     ["get-batch", "m1", "m2"]):
            self.invoke(argv)
        for request in self.agent.requests:
            self.assertIn(request["method"], {"accounts", "search", "get"})
            self.assertEqual(request["params"]["account"], ACCOUNT)

    def test_no_real_addresses_or_default_socket(self):
        self.assertNotEqual(str(self.ctx.socket_path), str(transport.DEFAULT_SOCKET))
        self.assertTrue(str(self.ctx.socket_path).startswith(self.temp.name))
        domains = {"example.com", "example.org", "example.net"}
        pattern = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)")
        for path in (SCRIPT, Path(__file__), DOCS):
            self.assertTrue(path.exists(), path)
            for match in pattern.finditer(path.read_text()):
                self.assertIn(match.group(1).lower(), domains, (path, match.group(0)))

    def test_source_has_no_stderr_usage(self):
        source = SCRIPT.read_text()
        self.assertNotIn("sys.stderr", source)
        self.assertNotIn("file=sys.stderr", source)

    def test_cli_stderr_empty_stdout_single_json(self):
        cases = [["bogus"], ["list"], ["get_verification_code"], ["--account", "x"],
                 ["--account=x", "accounts"], ["search", "--limit", "21"],
                 ["search", "--since-days", "0"], ["get", "bad id"], ["get", "a/b"],
                 ["--help"], ["-h"], [], ["accounts", "--help"],
                 ["get-batch"] + ["i%d" % i for i in range(6)]]
        for argv in cases:
            with self.subTest(argv=argv):
                merged = subprocess.run(
                    [sys.executable, "-B", "-E", "-S", "-X", "utf8", str(SCRIPT), *argv],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20,
                    env={"HOME": self.temp.name,
                         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
                self.assertEqual(merged.returncode, 2)
                # stdout+stderr merged is still exactly the one JSON document.
                self.assertEqual(json.loads(merged.stdout), USAGE_DOC)
                self.assertLessEqual(len(merged.stdout), pigi_oneshot.MAX_STDOUT)
                split = self.cli(argv)  # asserts stderr == b"" itself
                self.assertEqual(split.returncode, 2)
                self.assertEqual(json.loads(split.stdout + split.stderr), USAGE_DOC)

    def test_child_stderr_is_discarded_never_forwarded(self):
        # The child writes "transport or audit unavailable." on ITS stderr when
        # the audit DB path cannot be created; our stderr must stay empty and
        # stdout the fixed exit-5 JSON.
        blocker = self.root / "blocker"
        blocker.write_text("not a dir")
        ctx = pigi_oneshot.Context(
            ACCOUNT, {ALLOWED}, socket_path=self.agent.endpoint,
            audit_db=blocker / "audit.sqlite3", python=sys.executable,
            home=self.temp.name, now_ms=lambda: NOW)
        self.table["accounts"] = lambda params: accounts_result()
        code, out = self.invoke(["accounts"], ctx)  # invoke asserts stderr == ""
        self.assertEqual(code, 5)
        self.assertEqual(self.parse(out)["error"], "upstream_unavailable")
        self.assertEqual(self.agent.requests, [])

    def test_isolation_guard(self):
        home = self.root / "guard-home"
        home.mkdir()
        config = home / "oneshot.json"
        sock_dir = self.root / "guard-sock"
        sock_dir.mkdir()
        sock = sock_dir / "agent.sock"
        audit_path = self.root / "guard-audit.sqlite3"
        assert_isolated(str(home), str(config), str(sock), str(audit_path))
        for bad_home in (os.path.expanduser("~"),
                         pwd.getpwuid(os.getuid()).pw_dir, ORIGINAL_PINNED_HOME):
            with self.subTest(home=bad_home):
                with self.assertRaises(AssertionError):
                    assert_isolated(bad_home, str(config), str(sock), str(audit_path))
        real_home = os.path.expanduser("~")
        support = Path(real_home) / "Library" / "Application Support"
        with self.assertRaises(AssertionError):
            assert_isolated(str(home), str(config),
                            str(support / "pigi" / "agent.sock"), str(audit_path))
        with self.assertRaises(AssertionError):
            assert_isolated(str(home), str(config),
                            str(transport.DEFAULT_SOCKET), str(audit_path))
        with self.assertRaises(AssertionError):
            assert_isolated(str(home), str(config), str(sock),
                            str(audit.DEFAULT_AUDIT))
        with self.assertRaises(AssertionError):
            assert_isolated(str(home), str(support / "pigi" / "oneshot.json"),
                            str(sock), str(audit_path))
        # A path merely under the real home (like this checkout) is allowed.
        under = os.path.realpath(Path(__file__).parent)
        self.assertTrue(under.startswith(os.path.realpath(real_home)))
        assert_isolated(under, os.path.join(under, "oneshot.json"),
                        os.path.join(under, "agent.sock"),
                        os.path.join(under, "audit.sqlite3"))

    def test_main_harness_refuses_real_home(self):
        with patch.object(pigi_oneshot, "main") as mock_main:
            with self.assertRaises(AssertionError):
                self.invoke_main(["accounts"], ORIGINAL_PINNED_HOME)
        mock_main.assert_not_called()

    def test_main_contract_end_to_end(self):
        valid = {"account": ACCOUNT, "senders": [ALLOWED]}

        home, _ = self.make_home("m6-missing")  # no config file
        code, _, doc = self.invoke_main(["accounts"], home)
        self.assertEqual((code, doc), (6, CONFIG_DOC))

        home, _ = self.make_home("m6-mode")
        unsafe = home / "Library" / "Application Support" / "pigi" / "oneshot.json"
        unsafe.write_text(json.dumps(valid))
        os.chmod(unsafe, 0o644)
        code, _, doc = self.invoke_main(["accounts"], home)
        self.assertEqual((code, doc), (6, CONFIG_DOC))

        for argv in (["bogus"], ["--help"],
                     ["get-batch"] + ["i%d" % i for i in range(6)]):
            code, _, doc = self.invoke_main(argv, home)
            self.assertEqual((code, doc), (2, USAGE_DOC))

        home, _ = self.make_home("m7", valid)
        boom = patch.object(pigi_oneshot, "run_command",
                            side_effect=RuntimeError("boom"))
        code, _, doc = self.invoke_main(["accounts"], home, patches=(boom,))
        self.assertEqual((code, doc), (7, INTERNAL_DOC))

        home, _ = self.make_home("m5", valid)  # config ok, socket missing
        code, _, doc = self.invoke_main(["accounts"], home)
        self.assertEqual(code, 5)
        self.assertIn(doc["error"], FIXED_ERROR_CODES)

        home, _ = self.make_home("m0", valid, agent=True)
        self.table["accounts"] = lambda params: accounts_result()
        code, out, doc = self.invoke_main(["accounts"], home)
        self.assertEqual(code, 0)
        self.assertEqual(doc["command"], "accounts")
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)

        self.table["get"] = lambda params: get_result(
            make_message(params["messageID"], OTHER), SENTINEL)
        code, out, doc = self.invoke_main(["get", "m1"], home)
        self.assertEqual((code, doc["allowed"]), (3, False))
        self.assertNotIn(SENTINEL, out.decode("utf-8"))
        code, _, doc = self.invoke_main(["get-batch", "a", "b"], home)
        self.assertEqual(code, 3)
        self.assertEqual(doc["results"], [{"messageID": "a", "status": "filtered"},
                                          {"messageID": "b", "status": "filtered"}])

        def gone(params):
            raise AgentError("not_found")
        self.table["get"] = gone
        code, _, doc = self.invoke_main(["get", "m9"], home)
        self.assertEqual((code, doc), (4, {"contentTrust": "untrusted",
                                           "error": "not_found"}))

        self.table["get"] = lambda params: get_result(make_message("m1"), "x" * 100_000)
        code, out, doc = self.invoke_main(["get", "m1"], home)
        self.assertEqual((code, doc["truncated"]), (8, True))
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)


if __name__ == "__main__":
    unittest.main()
