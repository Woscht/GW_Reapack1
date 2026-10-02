"""Tests for timelog directory import."""

import hashlib
from pathlib import Path

from ptt_office import db
from ptt_office import ingest

FIXTURES = Path(__file__).resolve().parent / "fixtures"
SAMPLE_GUID = "ABC-GUID"


def _setup_timelogs_dir(tmp_path: Path) -> Path:
    timelogs = tmp_path / "timelogs"
    timelogs.mkdir()
    src = FIXTURES / "sample.timelog.jsonl"
    dest = timelogs / f"{SAMPLE_GUID}.timelog.jsonl"
    dest.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
    return timelogs


def test_event_id_sha256_hex():
    raw = '{"event":"session_end","span_accum":1}'
    guid = "my-guid"
    expected = hashlib.sha256(f"{guid}\n{raw}".encode()).hexdigest()
    assert ingest.event_id(guid, raw) == expected


def test_import_dir_loads_events(tmp_path):
    timelogs = _setup_timelogs_dir(tmp_path)
    conn = db.connect(tmp_path / "office.sqlite")
    db.init_schema(conn)

    stats = ingest.import_dir(conn, timelogs)
    assert stats["files_imported"] == 1
    assert stats["events_upserted"] == 8

    count = conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
    assert count == 8
    conn.close()


def test_import_dir_idempotent_double_import(tmp_path):
    timelogs = _setup_timelogs_dir(tmp_path)
    conn = db.connect(tmp_path / "office.sqlite")
    db.init_schema(conn)

    ingest.import_dir(conn, timelogs)
    stats2 = ingest.import_dir(conn, timelogs)
    assert stats2["files_skipped"] == 1
    assert stats2["events_upserted"] == 0

    count = conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
    assert count == 8
    conn.close()


def test_import_dir_ignores_tmp_and_failed(tmp_path):
    timelogs = _setup_timelogs_dir(tmp_path)
    (timelogs / "noise.timelog.jsonl.tmp").write_text("{}", encoding="utf-8")
    failed = timelogs / "_failed"
    failed.mkdir()
    (failed / "bad.timelog.jsonl").write_text("{}", encoding="utf-8")

    conn = db.connect(tmp_path / "office.sqlite")
    db.init_schema(conn)
    stats = ingest.import_dir(conn, timelogs)
    assert stats["files_imported"] == 1
    conn.close()


def test_import_dir_reimports_when_file_changes(tmp_path):
    timelogs = _setup_timelogs_dir(tmp_path)
    conn = db.connect(tmp_path / "office.sqlite")
    db.init_schema(conn)
    ingest.import_dir(conn, timelogs)

    log_path = timelogs / f"{SAMPLE_GUID}.timelog.jsonl"
    log_path.write_text(
        log_path.read_text(encoding="utf-8")
        + '{"ts":"2026-01-16T09:00:00.000Z","event":"session_end","session_id":"wall_5","span_accum":1,"project_guid":"ABC-GUID","project_name":"Show A","machine":"studio1"}\n',
        encoding="utf-8",
    )

    stats = ingest.import_dir(conn, timelogs)
    assert stats["files_imported"] == 1
    assert conn.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 9
    conn.close()
