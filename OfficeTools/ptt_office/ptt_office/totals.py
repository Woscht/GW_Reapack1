"""Aggregate totals and session lists from imported events."""

from __future__ import annotations

import sqlite3
from typing import Any


def _ts_in_range(ts: str, ts_from: str, ts_to: str) -> bool:
    if ts_from and ts < ts_from:
        return False
    if ts_to and ts > ts_to:
        return False
    return True


def _sum_from_rows(rows: list[sqlite3.Row]) -> dict[str, float]:
    session_span_s = 0.0
    rec_rolling_s = 0.0
    for row in rows:
        ev = row["event"]
        close = row["close_event"]
        if ev == "session_end" or (ev == "crash_close" and close == "session_end"):
            session_span_s += float(row["span_accum"] or 0)
        if ev == "rec_session_end" or (ev == "crash_close" and close == "rec_session_end"):
            rec_rolling_s += float(row["rec_accum"] or 0)
    return {"session_span_s": session_span_s, "rec_rolling_s": rec_rolling_s}


def project_totals(
    conn: sqlite3.Connection,
    guid: str,
    ts_from: str,
    ts_to: str,
) -> dict[str, float]:
    """Session-Span and Rec-Rolling for a project in an inclusive ts range."""
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        """
        SELECT event, close_event, span_accum, rec_accum, ts
        FROM events
        WHERE project_guid = ?
        ORDER BY ts
        """,
        (guid,),
    ).fetchall()
    filtered = [r for r in rows if _ts_in_range(r["ts"], ts_from, ts_to)]
    return _sum_from_rows(filtered)


def list_projects(conn: sqlite3.Connection, q: str | None = None) -> list[dict[str, Any]]:
    """One row per project_guid with latest name and last event ts."""
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        """
        SELECT
          project_guid AS guid,
          (
            SELECT project_name FROM events e2
            WHERE e2.project_guid = e.project_guid
              AND project_name IS NOT NULL AND project_name != ''
            ORDER BY ts DESC LIMIT 1
          ) AS name,
          MAX(ts) AS last_ts
        FROM events e
        GROUP BY project_guid
        ORDER BY last_ts DESC
        """
    ).fetchall()
    out: list[dict[str, Any]] = []
    needle = (q or "").strip().lower()
    for row in rows:
        item = {
            "guid": row["guid"],
            "name": row["name"] or "",
            "last_ts": row["last_ts"],
        }
        if needle:
            hay = f"{item['name']} {item['guid']}".lower()
            if needle not in hay:
                continue
        out.append(item)
    return out


def _is_wall_session_end(ev: str, close: str | None) -> bool:
    return ev == "session_end" or (ev == "crash_close" and close == "session_end")


def list_sessions(
    conn: sqlite3.Connection,
    guid: str,
    ts_from: str,
    ts_to: str,
) -> list[dict[str, Any]]:
    """Wall-clock sessions closed within the inclusive ts range."""
    conn.row_factory = sqlite3.Row
    events = conn.execute(
        """
        SELECT ts, event, session_id, span_accum, project_name, machine, close_event
        FROM events
        WHERE project_guid = ?
        ORDER BY ts
        """,
        (guid,),
    ).fetchall()

    starts: dict[str, list[dict[str, Any]]] = {}
    sessions: list[dict[str, Any]] = []

    for row in events:
        sid = row["session_id"]
        if row["event"] == "session_start" and sid:
            starts.setdefault(sid, []).append(dict(row))

        if not _is_wall_session_end(row["event"], row["close_event"]):
            continue
        if not _ts_in_range(row["ts"], ts_from, ts_to):
            continue
        if not sid:
            continue

        start_ts = None
        project_name = row["project_name"] or ""
        machines: set[str] = set()
        for start in starts.get(sid, []):
            if start["ts"] <= row["ts"]:
                start_ts = start["ts"]
                if start.get("project_name"):
                    project_name = start["project_name"]
        if row["machine"]:
            machines.add(row["machine"])
        for start in starts.get(sid, []):
            if start.get("machine"):
                machines.add(start["machine"])

        sessions.append(
            {
                "session_id": sid,
                "start_ts": start_ts,
                "end_ts": row["ts"],
                "span_s": float(row["span_accum"] or 0),
                "project_guid": guid,
                "project_name": project_name,
                "machines": sorted(machines),
            }
        )

    return sessions
