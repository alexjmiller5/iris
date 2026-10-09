"""Synthetic files for the Mac BackupUITests: a CLI-shaped soma.db, its gzip SQL dump
in the `soma export` shape, and an empty folder for the saved export. No real data."""

import gzip
import pathlib
import sqlite3
import sys

out = pathlib.Path(sys.argv[1])
(out / "save").mkdir(parents=True, exist_ok=True)
database = out / "soma.db"
database.unlink(missing_ok=True)
stamp = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"
notes = (
    "CREATE TABLE notes (id TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))), "
    f"title TEXT, body TEXT, created_at TEXT NOT NULL DEFAULT ({stamp}), "
    f"updated_at TEXT NOT NULL DEFAULT ({stamp}), deleted_at TEXT, hub_at TEXT)"
)
catalog = (
    "CREATE TABLE catalog_tables (id TEXT PRIMARY KEY, kind TEXT, display TEXT, purpose TEXT, "
    f"created_at TEXT NOT NULL DEFAULT ({stamp}), updated_at TEXT NOT NULL DEFAULT ({stamp}), "
    "deleted_at TEXT, hub_at TEXT)"
)
with sqlite3.connect(database) as conn:
    conn.execute(
        f"CREATE TABLE _schema_log (id INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT ({stamp}), ddl TEXT NOT NULL)"
    )
    for ddl in (notes, catalog):
        conn.execute(ddl)
        conn.execute("INSERT INTO _schema_log (ddl) VALUES (?)", (ddl,))
    conn.execute(
        "INSERT INTO catalog_tables (id, kind, display, purpose) VALUES ('notes', 'table', 'title', 'Synthetic notes')"
    )
    conn.execute(
        "INSERT INTO notes (id, title, body) VALUES ('synthetic-1', 'Synthetic restored note', '# From a backup')"
    )
    dump = "\n".join(["-- soma-dump: 1", *conn.iterdump()]) + "\n"
(out / "synthetic.sql.gz").write_bytes(gzip.compress(dump.encode()))
print(out)
