"""Tests for project totals and session listing."""

from pathlib import Path

from ptt_office import db
from ptt_office import ingest
from ptt_office import totals

FIXTURES = Path(__file__).resolve().parent / "fixtures"
SAMPLE_GUID = "ABC-GUID"


def _import_fixture(tmp_path):
    timelogs = tmp_path / "timelogs"
    timelogs.mkdir()
    dest = timelogs / f"{SAMPLE_GUID}.timelog.jsonl"
    dest.write_text(
        (FIXTURES / "sample.timelog.jsonl").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    conn = db.connect(tmp_path / "office.sqlite")
    db.init_schema(conn)
    ingest.import_dir(conn, timelogs)
    return conn


def test_project_totals_match_report_lua_rules(tmp_path):
    conn = _import_fixture(tmp_path)
    # January only: excludes wall_4 (999s in February)
    result = totals.project_totals(
        conn, SAMPLE_GUID, "2026-01-01T00:00:00.000Z", "2026-01-31T23:59:59.999Z"
    )
    # session: 120.5 + 60 + 5.5 (crash_close session_end) = 186.0
    assert result["session_span_s"] == 186.0
    # rec: 40 + 10 (crash_close rec_session_end) = 50
    assert result["rec_rolling_s"] == 50.0
    conn.close()


def test_project_totals_all_time(tmp_path):
    conn = _import_fixture(tmp_path)
    result = totals.project_totals(conn, SAMPLE_GUID, "", "9999-12-31T23:59:59.999Z")
    assert result["session_span_s"] == 186.0 + 999.0
    assert result["rec_rolling_s"] == 50.0
    conn.close()


def test_list_projects(tmp_path):
    conn = _import_fixture(tmp_path)
    projects = totals.list_projects(conn)
    assert len(projects) == 1
    assert projects[0]["guid"] == SAMPLE_GUID
    assert projects[0]["name"] == "Show A"
    assert projects[0]["last_ts"] == "2026-02-01T08:00:00.000Z"
    conn.close()


def test_list_projects_search(tmp_path):
    conn = _import_fixture(tmp_path)
    assert len(totals.list_projects(conn, q="show")) == 1
    assert len(totals.list_projects(conn, q="nomatch")) == 0
    assert len(totals.list_projects(conn, q="abc-guid")) == 1
    conn.close()


def test_list_sessions_in_range(tmp_path):
    conn = _import_fixture(tmp_path)
    sessions = totals.list_sessions(
        conn,
        SAMPLE_GUID,
        "2026-01-15T00:00:00.000Z",
        "2026-01-15T23:59:59.999Z",
    )
    assert len(sessions) == 3
    by_id = {s["session_id"]: s for s in sessions}
    assert by_id["wall_1"]["span_s"] == 120.5
    assert by_id["wall_1"]["start_ts"] == "2026-01-15T09:00:00.000Z"
    assert by_id["wall_1"]["end_ts"] == "2026-01-15T10:00:00.000Z"
    assert "studio1" in by_id["wall_1"]["machines"]
    assert by_id["wall_2"]["span_s"] == 60.0
    assert set(by_id["wall_3"]["machines"]) == {"studio1"}
    conn.close()
