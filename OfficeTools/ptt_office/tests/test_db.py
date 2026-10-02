"""Tests for SQLite schema initialization."""

import sqlite3

from ptt_office import db


def test_connect_returns_sqlite_connection(tmp_path):
    path = tmp_path / "test.sqlite"
    conn = db.connect(path)
    assert isinstance(conn, sqlite3.Connection)
    conn.close()


def test_init_schema_creates_files_table(tmp_path):
    conn = db.connect(tmp_path / "test.sqlite")
    db.init_schema(conn)
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='files'"
    ).fetchone()
    assert row is not None
    cols = {
        r[1]: r[2]
        for r in conn.execute("PRAGMA table_info(files)").fetchall()
    }
    assert cols["path"] == "TEXT"
    assert "guid" in cols
    assert "mtime_ns" in cols
    assert "size" in cols
    assert "last_imported_at" in cols
    conn.close()


def test_init_schema_creates_events_table(tmp_path):
    conn = db.connect(tmp_path / "test.sqlite")
    db.init_schema(conn)
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='events'"
    ).fetchone()
    assert row is not None
    cols = {
        r[1]: r[2]
        for r in conn.execute("PRAGMA table_info(events)").fetchall()
    }
    assert cols["event_id"] == "TEXT"
    assert cols["project_guid"] == "TEXT"
    assert "project_name" in cols
    assert "machine" in cols
    assert cols["ts"] == "TEXT"
    assert cols["event"] == "TEXT"
    assert "session_id" in cols
    assert "span_accum" in cols
    assert "rec_accum" in cols
    assert "close_event" in cols
    assert cols["raw_line"] == "TEXT"
    conn.close()


def test_init_schema_creates_indexes_and_view(tmp_path):
    conn = db.connect(tmp_path / "test.sqlite")
    db.init_schema(conn)
    indexes = {
        r[0]
        for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'"
        ).fetchall()
    }
    assert "idx_events_guid_ts" in indexes
    assert "idx_events_name" in indexes
    view = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='view' AND name='project_names'"
    ).fetchone()
    assert view is not None
    conn.close()


def test_init_schema_idempotent(tmp_path):
    conn = db.connect(tmp_path / "test.sqlite")
    db.init_schema(conn)
    db.init_schema(conn)
    tables = [
        r[0]
        for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()
    ]
    assert tables == ["events", "files"]
    conn.close()
