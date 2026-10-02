"""FastAPI web UI for office time totals."""

from __future__ import annotations

import csv
import io
import os
import sqlite3
from calendar import monthrange
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates

from ptt_office import db
from ptt_office import ingest
from ptt_office import totals

_TEMPLATES = Path(__file__).resolve().parent / "templates"


def _iso_z(dt: datetime) -> str:
    ms = dt.microsecond // 1000
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{ms:03d}Z"


def default_range() -> tuple[str, str]:
    """Inclusive UTC range for the current calendar month."""
    now = datetime.now(timezone.utc)
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    last_day = monthrange(now.year, now.month)[1]
    end = now.replace(
        day=last_day, hour=23, minute=59, second=59, microsecond=999000
    )
    return _iso_z(start), _iso_z(end)


def resolve_range(ts_from: str, ts_to: str) -> tuple[str, str]:
    if ts_from.strip() and ts_to.strip():
        return ts_from.strip(), ts_to.strip()
    return default_range()


def format_seconds(value: float) -> str:
    return f"{value:.3f}"


def import_status(conn: sqlite3.Connection) -> dict[str, Any]:
    row = conn.execute(
        "SELECT MAX(last_imported_at) AS last_at, COUNT(*) AS n FROM files"
    ).fetchone()
    return {
        "last_import_at": row[0] if row and row[0] else None,
        "files_count": int(row[1]) if row else 0,
    }


def projects_with_totals(
    conn: sqlite3.Connection,
    q: str,
    ts_from: str,
    ts_to: str,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for proj in totals.list_projects(conn, q=q or None):
        t = totals.project_totals(conn, proj["guid"], ts_from, ts_to)
        rows.append(
            {
                **proj,
                "session_span_s": t["session_span_s"],
                "rec_rolling_s": t["rec_rolling_s"],
                "session_span_fmt": format_seconds(t["session_span_s"]),
                "rec_rolling_fmt": format_seconds(t["rec_rolling_s"]),
            }
        )
    return rows


def create_app(
    sqlite_path: Path | None = None,
    timelogs_dir: Path | None = None,
) -> FastAPI:
    db_path = Path(
        sqlite_path or os.environ.get("PTT_SQLITE_PATH", "ptt_office.sqlite")
    )
    logs_dir = Path(
        timelogs_dir or os.environ.get("PTT_TIMELOGS_DIR", "timelogs")
    )

    app = FastAPI(title="PTT Office")
    templates = Jinja2Templates(directory=str(_TEMPLATES))

    def open_conn() -> sqlite3.Connection:
        conn = db.connect(db_path)
        db.init_schema(conn)
        return conn

    @app.get("/", response_class=HTMLResponse)
    def index(
        request: Request,
        q: str = "",
        from_ts: str = Query("", alias="from"),
        to_ts: str = Query("", alias="to"),
    ):
        ts_from, ts_to = resolve_range(from_ts, to_ts)
        conn = open_conn()
        try:
            status = import_status(conn)
            projects = projects_with_totals(conn, q, ts_from, ts_to)
        finally:
            conn.close()
        return templates.TemplateResponse(
            request,
            "index.html",
            {
                "q": q,
                "from_ts": ts_from,
                "to_ts": ts_to,
                "projects": projects,
                "status": status,
            },
        )

    @app.get("/projects/{guid}", response_class=HTMLResponse)
    def project_detail(
        request: Request,
        guid: str,
        from_ts: str = Query("", alias="from"),
        to_ts: str = Query("", alias="to"),
    ):
        ts_from, ts_to = resolve_range(from_ts, to_ts)
        conn = open_conn()
        try:
            status = import_status(conn)
            t = totals.project_totals(conn, guid, ts_from, ts_to)
            sessions = totals.list_sessions(conn, guid, ts_from, ts_to)
            names = totals.list_projects(conn)
            name = next((p["name"] for p in names if p["guid"] == guid), "")
        finally:
            conn.close()
        for s in sessions:
            s["span_fmt"] = format_seconds(s["span_s"])
        return templates.TemplateResponse(
            request,
            "project.html",
            {
                "guid": guid,
                "name": name,
                "from_ts": ts_from,
                "to_ts": ts_to,
                "totals": {
                    "session_span_s": t["session_span_s"],
                    "rec_rolling_s": t["rec_rolling_s"],
                    "session_span_fmt": format_seconds(t["session_span_s"]),
                    "rec_rolling_fmt": format_seconds(t["rec_rolling_s"]),
                },
                "sessions": sessions,
                "status": status,
            },
        )

    @app.get("/export.csv")
    def export_csv(
        q: str = "",
        from_ts: str = Query("", alias="from"),
        to_ts: str = Query("", alias="to"),
    ):
        ts_from, ts_to = resolve_range(from_ts, to_ts)
        conn = open_conn()
        try:
            projects = projects_with_totals(conn, q, ts_from, ts_to)
        finally:
            conn.close()

        buf = io.StringIO()
        writer = csv.writer(buf)
        writer.writerow(
            ["project_name", "project_guid", "session_span_s", "rec_rolling_s"]
        )
        for p in projects:
            writer.writerow(
                [
                    p["name"],
                    p["guid"],
                    f"{p['session_span_s']:.3f}",
                    f"{p['rec_rolling_s']:.3f}",
                ]
            )
        return Response(
            content=buf.getvalue(),
            media_type="text/csv; charset=utf-8",
            headers={"Content-Disposition": 'attachment; filename="export.csv"'},
        )

    @app.post("/refresh")
    def refresh():
        conn = open_conn()
        try:
            ingest.import_dir(conn, logs_dir)
        finally:
            conn.close()
        return RedirectResponse("/", status_code=303)

    return app


app = create_app()
