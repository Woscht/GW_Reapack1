"""Import mirrored timelog JSONL files into SQLite."""

from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Union

PathLike = Union[str, Path]

_TIMELOG_SUFFIX = ".timelog.jsonl"


def event_id(guid: str, raw_line: str) -> str:
    """Stable event key: sha256(guid + newline + raw line), hex digest."""
    payload = f"{guid}\n{raw_line}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _guid_from_filename(path: Path) -> str | None:
    name = path.name
    if not name.endswith(_TIMELOG_SUFFIX):
        return None
    return name[: -len(_TIMELOG_SUFFIX)]


def _should_skip_path(path: Path, timelogs_dir: Path) -> bool:
    if path.suffix == ".tmp" or path.name.endswith(".tmp"):
        return True
    try:
        path.relative_to(timelogs_dir / "_failed")
        return True
    except ValueError:
        return False


def _parse_event(guid: str, raw_line: str) -> dict[str, Any] | None:
    raw_line = raw_line.strip()
    if not raw_line:
        return None
    try:
        obj = json.loads(raw_line)
    except json.JSONDecodeError:
        return None
    if not isinstance(obj, dict):
        return None
    return {
        "event_id": event_id(guid, raw_line),
        "project_guid": obj.get("project_guid") or guid,
        "project_name": obj.get("project_name"),
        "machine": obj.get("machine"),
        "ts": obj.get("ts") or "",
        "event": obj.get("event") or "",
        "session_id": obj.get("session_id"),
        "span_accum": obj.get("span_accum"),
        "rec_accum": obj.get("rec_accum"),
        "close_event": obj.get("close_event"),
        "raw_line": raw_line,
    }


def _import_file(conn: sqlite3.Connection, path: Path, guid: str) -> int:
    stat = path.stat()
    mtime_ns = stat.st_mtime_ns
    size = stat.st_size
    rel_path = str(path.resolve())

    row = conn.execute(
        "SELECT mtime_ns, size FROM files WHERE path = ?", (rel_path,)
    ).fetchone()
    if row and row[0] == mtime_ns and row[1] == size:
        return 0

    text = path.read_text(encoding="utf-8")
    upserted = 0
    for line in text.splitlines():
        ev = _parse_event(guid, line)
        if ev is None or not ev["ts"] or not ev["event"]:
            continue
        conn.execute(
            """
            INSERT INTO events (
              event_id, project_guid, project_name, machine, ts, event,
              session_id, span_accum, rec_accum, close_event, raw_line
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(event_id) DO UPDATE SET
              project_guid = excluded.project_guid,
              project_name = excluded.project_name,
              machine = excluded.machine,
              ts = excluded.ts,
              event = excluded.event,
              session_id = excluded.session_id,
              span_accum = excluded.span_accum,
              rec_accum = excluded.rec_accum,
              close_event = excluded.close_event,
              raw_line = excluded.raw_line
            """,
            (
                ev["event_id"],
                ev["project_guid"],
                ev["project_name"],
                ev["machine"],
                ev["ts"],
                ev["event"],
                ev["session_id"],
                ev["span_accum"],
                ev["rec_accum"],
                ev["close_event"],
                ev["raw_line"],
            ),
        )
        upserted += 1

    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        """
        INSERT INTO files (path, guid, mtime_ns, size, last_imported_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
          guid = excluded.guid,
          mtime_ns = excluded.mtime_ns,
          size = excluded.size,
          last_imported_at = excluded.last_imported_at
        """,
        (rel_path, guid, mtime_ns, size, now),
    )
    conn.commit()
    return upserted


def import_dir(conn: sqlite3.Connection, timelogs_dir: PathLike) -> dict[str, int]:
    """Scan ``timelogs_dir`` for ``*.timelog.jsonl`` and upsert events."""
    root = Path(timelogs_dir)
    stats = {
        "files_scanned": 0,
        "files_imported": 0,
        "files_skipped": 0,
        "events_upserted": 0,
    }
    if not root.is_dir():
        return stats

    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if _should_skip_path(path, root):
            continue
        if not path.name.endswith(_TIMELOG_SUFFIX):
            continue
        guid = _guid_from_filename(path)
        if not guid:
            continue
        stats["files_scanned"] += 1
        before = conn.execute(
            "SELECT mtime_ns, size FROM files WHERE path = ?",
            (str(path.resolve()),),
        ).fetchone()
        stat = path.stat()
        unchanged = (
            before is not None
            and before[0] == stat.st_mtime_ns
            and before[1] == stat.st_size
        )
        if unchanged:
            stats["files_skipped"] += 1
            continue
        n = _import_file(conn, path, guid)
        stats["files_imported"] += 1
        stats["events_upserted"] += n
    return stats
