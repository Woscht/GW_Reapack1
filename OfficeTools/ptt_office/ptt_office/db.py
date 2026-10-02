"""SQLite connection and schema for the office importer."""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Union

PathLike = Union[str, Path]

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS files (
  path TEXT PRIMARY KEY,
  guid TEXT NOT NULL,
  mtime_ns INTEGER,
  size INTEGER,
  last_imported_at TEXT
);

CREATE TABLE IF NOT EXISTS events (
  event_id TEXT PRIMARY KEY,
  project_guid TEXT NOT NULL,
  project_name TEXT,
  machine TEXT,
  ts TEXT NOT NULL,
  event TEXT NOT NULL,
  session_id TEXT,
  span_accum REAL,
  rec_accum REAL,
  close_event TEXT,
  raw_line TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_events_guid_ts ON events(project_guid, ts);
CREATE INDEX IF NOT EXISTS idx_events_name ON events(project_name);

CREATE VIEW IF NOT EXISTS project_names AS
  SELECT project_guid, project_name, MAX(ts) AS last_ts
  FROM events
  WHERE project_name IS NOT NULL AND project_name != ''
  GROUP BY project_guid, project_name;
"""


def connect(path: PathLike) -> sqlite3.Connection:
    """Open (and create if needed) a SQLite database at ``path``."""
    conn = sqlite3.connect(str(path))
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_schema(conn: sqlite3.Connection) -> None:
    """Create tables, indexes, and views per central-collection spec."""
    conn.executescript(_SCHEMA_SQL)
    conn.commit()
