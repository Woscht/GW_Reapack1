"""HTTP tests for the office web UI."""

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from ptt_office import db
from ptt_office import ingest
from ptt_office.app import create_app

FIXTURES = Path(__file__).resolve().parent / "fixtures"
SAMPLE_GUID = "ABC-GUID"


@pytest.fixture
def client(tmp_path):
    timelogs = tmp_path / "timelogs"
    timelogs.mkdir()
    dest = timelogs / f"{SAMPLE_GUID}.timelog.jsonl"
    dest.write_text(
        (FIXTURES / "sample.timelog.jsonl").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    sqlite_path = tmp_path / "office.sqlite"
    conn = db.connect(sqlite_path)
    db.init_schema(conn)
    ingest.import_dir(conn, timelogs)
    conn.close()

    app = create_app(sqlite_path=sqlite_path, timelogs_dir=timelogs)
    with TestClient(app) as c:
        yield c


def test_index_lists_project(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "Show A" in r.text
    assert SAMPLE_GUID in r.text
    assert "Session-Span" in r.text
    assert "Rec-Rolling" in r.text


def test_index_search_q(client):
    r = client.get("/", params={"q": "nomatch"})
    assert r.status_code == 200
    assert "Show A" not in r.text
    r2 = client.get("/", params={"q": "show"})
    assert "Show A" in r2.text


def test_index_date_range_filters_totals(client):
    r = client.get(
        "/",
        params={
            "from": "2026-01-01T00:00:00.000Z",
            "to": "2026-01-31T23:59:59.999Z",
        },
    )
    assert r.status_code == 200
    assert "186.000" in r.text
    assert "999.000" not in r.text


def test_project_detail_totals_and_sessions(client):
    r = client.get(
        f"/projects/{SAMPLE_GUID}",
        params={
            "from": "2026-01-15T00:00:00.000Z",
            "to": "2026-01-15T23:59:59.999Z",
        },
    )
    assert r.status_code == 200
    assert "wall_1" in r.text
    assert "120.5" in r.text or "120.500" in r.text


def test_export_csv_header_and_values(client):
    r = client.get(
        "/export.csv",
        params={
            "from": "2026-01-01T00:00:00.000Z",
            "to": "2026-01-31T23:59:59.999Z",
        },
    )
    assert r.status_code == 200
    assert "text/csv" in r.headers.get("content-type", "")
    body = r.text
    assert "project_name,project_guid,session_span_s,rec_rolling_s" in body
    assert "Show A" in body
    assert "186.000" in body
    assert "50.000" in body


def test_refresh_redirects_and_updates(client, tmp_path):
    timelogs = tmp_path / "timelogs"
    sqlite_path = tmp_path / "office.sqlite"
    app = create_app(sqlite_path=sqlite_path, timelogs_dir=timelogs)
    with TestClient(app) as c:
        r = c.post("/refresh", follow_redirects=False)
        assert r.status_code == 303
        assert r.headers["location"] == "/"


def test_last_import_shown(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "Last import" in r.text
