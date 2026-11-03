"""Private, content-free durable invocation ledger, separate from mail.db."""
import os
from pathlib import Path
import sqlite3
import stat
import time

DEFAULT_AUDIT = Path.home() / "Library/Application Support/pigi-mcp/audit.sqlite3"


class Audit:
    def __init__(self, path=DEFAULT_AUDIT):
        self.db = None
        path = Path(path).expanduser()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        parent = path.parent.lstat()
        if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid()
                or stat.S_IMODE(parent.st_mode) != 0o700):
            raise OSError("Unsafe audit directory")
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise OSError("Unsafe audit file")
        finally:
            os.close(fd)
        self.db = sqlite3.connect(path, timeout=2)
        self.db.execute("PRAGMA journal_mode=DELETE")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("""CREATE TABLE IF NOT EXISTS tool_calls(
            id INTEGER PRIMARY KEY, started_ms INTEGER NOT NULL, tool TEXT NOT NULL,
            outcome TEXT NOT NULL, duration_ms INTEGER NOT NULL)""")
        self.db.commit()

    def begin(self, tool):
        cursor = self.db.execute("INSERT INTO tool_calls(started_ms,tool,outcome,duration_ms) VALUES(?,?,'started',0)",
                                 (time.time_ns() // 1_000_000, tool))
        self.db.commit()
        return cursor.lastrowid

    def finish(self, row, outcome, duration):
        self.db.execute("UPDATE tool_calls SET outcome=?,duration_ms=? WHERE id=?", (outcome, duration, row))
        self.db.commit()

    def close(self):
        if self.db is not None:
            self.db.close()
