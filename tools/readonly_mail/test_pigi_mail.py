"""All fixtures are synthetic. Never open the user's mail store in tests."""
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from pigi_mail import MailError, MailReader, MCPServer

SCRIPT = Path(__file__).with_name("pigi_mail.py")
ENGINE = SCRIPT.parents[2] / "Pigi/Engine/LocalEngine.swift"


class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # URI metacharacters must be treated as filename characters.
        self.path = Path(self.temp.name) / "mail ?#&测试.db"
        self.db = sqlite3.connect(self.path)
        self.addCleanup(self.db.close)
        # Use the checked-out app's actual DDL, so drift is visible in tests.
        source = ENGINE.read_text()
        ddl = re.search(r"CREATE TABLE IF NOT EXISTS messages\(.*?\)\s*\"\"\"", source, re.S)
        self.db.execute(ddl.group(0).removesuffix('"""').strip())
        ddl = re.search(r"CREATE VIRTUAL TABLE IF NOT EXISTS fts[^\"]+", source)
        self.db.execute(ddl.group(0))
        for account, id, date, status, subject, body in [
            ("alpha@example.invalid", "same", 30, "inbox", "Launch meeting", "synthetic launch agenda"),
            ("beta@example.invalid", "same", 20, "archived", "Launch notes", "synthetic launch summary"),
            ("alpha@example.invalid", "removed", 40, "deleted", "Launch deleted", "launch removed"),
            ("alpha@example.invalid", "no-body", 10, "inbox", "No index", None),
        ]:
            cur = self.db.execute("INSERT INTO messages(account,id,date,status,subject,unread,labels) "
                                  "VALUES(?,?,?,?,?,1,'[\"INBOX\"]')", (account, id, date, status, subject))
            if body is not None:
                self.db.execute("INSERT INTO fts(rowid,subject,sender,body) VALUES(?,?,?,?)",
                                (cur.lastrowid, subject, "Synthetic Sender", body))
        self.db.commit()
        self.reader = MailReader(self.path)

    def cli(self, *args, input=None):
        return subprocess.run([sys.executable, "-B", str(SCRIPT), "--db", str(self.path), *args],
                              input=input, text=True, capture_output=True, timeout=10)

    def test_list_order_paging_account_and_deleted(self):
        rows = self.reader.list_messages()["messages"]
        self.assertEqual([r["id"] for r in rows], ["same", "same", "no-body"])
        self.assertNotIn("body", rows[0])
        self.assertEqual(self.reader.list_messages(limit=1, offset=1)["messages"][0]["account"],
                         "beta@example.invalid")
        self.assertEqual(len(self.reader.list_messages(account="alpha@example.invalid")["messages"]), 2)

    def test_search_real_trigram_index_and_account(self):
        self.assertEqual(len(self.reader.search_messages("launch")["messages"]), 2)
        found = self.reader.search_messages("summary", account="beta@example.invalid")["messages"]
        self.assertEqual([r["subject"] for r in found], ["Launch notes"])
        self.assertEqual(self.reader.search_messages("la")["messages"], [])
        self.assertEqual(self.reader.search_messages("absent")["messages"], [])

    def test_read_composite_key_body_and_missing_index(self):
        a = self.reader.read_message("alpha@example.invalid", "same", body_limit=9)
        b = self.reader.read_message("beta@example.invalid", "same")
        self.assertEqual(a["body"], "synthetic")
        self.assertTrue(a["body_truncated"])
        self.assertEqual(b["body"], "synthetic launch summary")
        self.assertFalse(b["body_truncated"])
        missing = self.reader.read_message("alpha@example.invalid", "no-body")
        self.assertFalse(missing["body_available"])
        self.assertIsNone(missing["body"])
        for id in ("absent", "removed"):
            with self.assertRaises(MailError):
                self.reader.read_message("alpha@example.invalid", id)

    def test_readonly_and_unchanged_files(self):
        before = hashlib.sha256(self.path.read_bytes()).digest()
        names = set(self.path.parent.iterdir())
        db = self.reader.connect()
        try:
            self.assertEqual(db.execute("PRAGMA query_only").fetchone()[0], 1)
            # Even disabling query_only cannot override mode=ro.
            db.execute("PRAGMA query_only=OFF")
            with self.assertRaises(sqlite3.OperationalError):
                db.execute("UPDATE messages SET unread=0")
        finally:
            db.close()
        self.reader.list_messages()
        self.reader.search_messages("launch")
        self.reader.read_message("alpha@example.invalid", "same")
        self.assertEqual(before, hashlib.sha256(self.path.read_bytes()).digest())
        self.assertEqual(names, set(self.path.parent.iterdir()))
        self.assertEqual(self.db.execute("SELECT sum(unread) FROM messages").fetchone()[0], 4)

    def test_wal_reads_latest_committed_data(self):
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("UPDATE messages SET subject='Updated synthetic subject' WHERE rowid=1")
        self.db.commit()
        before = {p.name: p.read_bytes() for p in self.path.parent.iterdir() if not p.name.endswith('-shm')}
        self.assertEqual(self.reader.read_message("alpha@example.invalid", "same")["subject"],
                         "Updated synthetic subject")
        after = {p.name: p.read_bytes() for p in self.path.parent.iterdir() if not p.name.endswith('-shm')}
        self.assertEqual(before, after)

    def test_missing_corrupt_or_drifted_database_fails_safely(self):
        missing = self.path.parent / "missing.db"
        with self.assertRaises(MailError):
            MailReader(missing).list_messages()
        self.assertFalse(missing.exists())
        corrupt = self.path.parent / "corrupt.db"
        corrupt.write_text("SYNTHETIC_PRIVATE_SENTINEL")
        with self.assertRaises(MailError) as error:
            MailReader(corrupt).list_messages()
        self.assertNotIn("SYNTHETIC_PRIVATE_SENTINEL", str(error.exception))
        self.db.execute("ALTER TABLE messages RENAME COLUMN subject TO incompatible")
        with self.assertRaises(MailError):
            self.reader.list_messages()

    def test_validation_and_injection(self):
        for args in ({"limit": 0}, {"limit": 101}, {"limit": True}, {"offset": -1}, {"account": ""}):
            with self.subTest(args=args), self.assertRaises(MailError):
                self.reader.list_messages(**args)
        self.assertEqual(self.reader.list_messages(account="' OR 1=1 --")["messages"], [])
        with self.assertRaises(MailError) as error:
            self.reader.search_messages('"SYNTHETIC_PRIVATE_SENTINEL')
        self.assertNotIn("SYNTHETIC_PRIVATE_SENTINEL", str(error.exception))
        self.assertEqual(len(self.reader.list_messages()["messages"]), 3)

    def test_cli_all_operations(self):
        for args in [("list", "--limit", "1"), ("search", "launch"),
                     ("read", "--account", "beta@example.invalid", "--id", "same")]:
            with self.subTest(args=args):
                result = self.cli(*args)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stderr, "")
                self.assertIsInstance(json.loads(result.stdout), dict)
        result = self.cli("search", '"SYNTHETIC_PRIVATE_SENTINEL')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("SYNTHETIC_PRIVATE_SENTINEL", result.stderr)

    def test_mcp_subprocess_handshake_discovery_and_calls(self):
        def request(id, method, params=None):
            return {"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}
        messages = [request(1, "initialize", {"protocolVersion": "2025-11-25",
                    "capabilities": {}, "clientInfo": {"name": "synthetic-test", "version": "1"}}),
                    {"jsonrpc": "2.0", "method": "notifications/initialized"},
                    request(2, "tools/list"), request(3, "ping")]
        for id, name, args in [(4, "list_messages", {}),
                               (5, "search_messages", {"query": "launch"}),
                               (6, "read_message", {"account": "beta@example.invalid", "id": "same"}),
                               (7, "search_messages", {"query": '"SYNTHETIC_PRIVATE_SENTINEL'}),
                               (8, "list_messages", {"limit": 0}),
                               (9, "read_message", {}),
                               (10, "write_message", {})]:
            messages.append(request(id, "tools/call", {"name": name, "arguments": args}))
        result = self.cli("mcp", input="\n".join(json.dumps(m) for m in messages) + "\ninvalid\n")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(responses), 11)
        by_id = {r["id"]: r for r in responses}
        self.assertEqual(by_id[1]["result"]["protocolVersion"], "2025-11-25")
        self.assertEqual(len(by_id[2]["result"]["tools"]), 3)
        self.assertEqual(by_id[3]["result"], {})
        for id in (4, 5, 6):
            self.assertFalse(by_id[id]["result"]["isError"])
        self.assertEqual(len(json.loads(by_id[5]["result"]["content"][0]["text"])["messages"]), 2)
        self.assertEqual(json.loads(by_id[6]["result"]["content"][0]["text"])["body"],
                         "synthetic launch summary")
        for id in (7, 8):
            self.assertTrue(by_id[id]["result"]["isError"])
        for id in (9, 10):
            self.assertEqual(by_id[id]["error"]["code"], -32602)
        self.assertEqual(by_id[None]["error"]["code"], -32700)
        self.assertNotIn("SYNTHETIC_PRIVATE_SENTINEL", result.stdout)

    def test_mcp_malformed_requests_and_initialization_gate(self):
        server = MCPServer(self.reader)
        for message in ([], {}, {"jsonrpc": "2.0", "id": [], "method": "ping"}):
            self.assertEqual(server.handle(message)["error"]["code"], -32600)
        response = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        self.assertEqual(response["error"]["code"], -32000)
        self.assertIsNone(server.handle({"jsonrpc": "2.0", "method": "notifications/cancelled"}))


if __name__ == "__main__":
    unittest.main()
