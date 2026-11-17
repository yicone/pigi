"""Synthetic fixtures only: fake agent.sock in a short temp dir, never real mail or HOME."""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

import pigi_oneshot
from pigi_mcp import TRUST_NOTICE
import transport

SCRIPT = Path(__file__).with_name("pigi_oneshot.py")
DOCS = Path(__file__).resolve().parent.parent.parent / "docs" / "pigi-oneshot.md"
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

    def stop_agent(self):
        self.agent.stop()
        self.assertFalse(self.agent.is_alive())
        self.assertEqual(self.agent.errors, [])

    def invoke(self, argv, ctx=None):
        with contextlib.redirect_stderr(io.StringIO()):
            return pigi_oneshot.execute(argv, ctx or self.ctx)

    def parse(self, out):
        return json.loads(out.decode("utf-8").strip())

    def cli(self, args):
        return subprocess.run(
            [sys.executable, "-B", "-E", "-S", "-X", "utf8", str(SCRIPT), *args],
            capture_output=True, timeout=20,
            env={"HOME": self.temp.name, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})

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
                self.assertEqual((code, out), (2, b""))
                result = self.cli(argv)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"pigi-oneshot: invalid arguments\n")
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
                self.assertEqual(self.invoke(["get", bad]), (2, b""))
        for argv in (["get", "-abc"], ["get"], ["get", "ok", "extra"]):
            result = self.cli(argv)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stderr, b"pigi-oneshot: invalid arguments\n")
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
        self.assertEqual(self.invoke(["get-batch"] + ["m%d" % i for i in range(6)]), (2, b""))
        self.assertEqual(self.invoke(["get-batch"]), (2, b""))
        result = self.cli(["get-batch"] + ["m%d" % i for i in range(6)])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.agent.requests, [])

    def test_unimplemented_and_scope_options_rejected(self):
        rejected = [["list"], ["get_verification_code"], ["unknown"], [],
                    ["--account", "x", "accounts"], ["accounts", "--account", "x"],
                    ["--account=x", "accounts"], ["search", "extra"]]
        for argv in rejected:
            with self.subTest(argv=argv):
                self.assertEqual(self.invoke(argv), (2, b""))
                result = self.cli(argv)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b"")
        self.assertEqual(self.agent.requests, [])
        source = SCRIPT.read_text()
        for forbidden in ('"list"', '"codes"', "get_verification_code", "list_messages"):
            self.assertNotIn(forbidden, source)

    def test_truncation_marker_and_cap(self):
        big = [make_message("m%d" % i, ALLOWED, snippet="A" * 30_000) for i in range(3)]
        self.table["search"] = lambda params: search_result(big)
        code, out = self.invoke(["search", "--limit", "20"])
        self.assertEqual(code, 0)
        self.assertLessEqual(len(out), pigi_oneshot.MAX_STDOUT)
        self.assertTrue(out.endswith(pigi_oneshot.TRUNCATION_MARKER))
        self.table["search"] = lambda params: search_result([make_message("m1")])
        code, out = self.invoke(["search"])
        self.assertEqual(code, 0)
        self.assertNotIn(pigi_oneshot.TRUNCATION_MARKER, out)
        self.assertLess(len(out), pigi_oneshot.MAX_STDOUT)

    def test_config_loader_fails_closed(self):
        home = self.root / "cfg-home"
        config_dir = home / "Library" / "Application Support" / "pigi"
        config_path = config_dir / "oneshot.json"

        def expect_six():
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    pigi_oneshot.load_config(str(home))
            self.assertEqual(raised.exception.code, 6)

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
            with contextlib.redirect_stderr(io.StringIO()) as err:
                code, out = pigi_oneshot.execute(["accounts"], self.ctx)
        self.assertEqual((code, out), (7, b""))
        self.assertEqual(err.getvalue(), "pigi-oneshot: internal error\n")

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


if __name__ == "__main__":
    unittest.main()
