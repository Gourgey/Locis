import copy
import io
import json
import zipfile

import pytest

from locis_pipeline.demo import DemoDTROSource, demo_records
from locis_pipeline.dtro_client import FixtureDTROSource, envelope_from_row, iter_extract
from locis_pipeline.ingest import STATE_LAST_SYNC, incremental_sync, initial_import
from locis_pipeline.store import MIGRATIONS, Store


class ListSource:
    """A D-TRO source over in-memory records and events."""

    def __init__(self, records, events=()):
        self.records = {r["id"]: r for r in records}
        self.events = list(events)

    def iter_all_records(self):
        yield from self.records.values()

    def iter_events(self, since, until):
        return (e for e in self.events if since <= e["eventTime"] <= until)

    def get_record(self, dtro_id):
        return self.records.get(dtro_id)


def feature_count(store):
    return store.db.execute("SELECT COUNT(*) FROM features").fetchone()[0]


def test_initial_import_stores_raw_payload_and_features(store):
    report = initial_import(store, DemoDTROSource())
    assert report.failed == 0
    assert report.created == len(demo_records())
    raw = store.db.execute("SELECT raw_payload FROM dtro_records WHERE id = 'demo-01'").fetchone()[0]
    assert json.loads(raw)["data"]["source"]["reference"] == "DEMO-01"
    assert feature_count(store) > 30
    assert store.get_state("import_progress") == "complete"


def test_reimport_is_idempotent(store):
    initial_import(store, DemoDTROSource())
    before = feature_count(store)
    report = initial_import(store, DemoDTROSource())
    assert report.created == 0 and report.updated == 0
    assert report.unchanged == len(demo_records())
    assert feature_count(store) == before


def test_unsupported_schema_version_is_preserved_but_not_published(store):
    initial_import(store, DemoDTROSource())
    row = store.db.execute("SELECT parse_status, raw_payload FROM dtro_records WHERE id = 'demo-38'").fetchone()
    assert row["parse_status"] == "unsupported"
    assert json.loads(row["raw_payload"])["schemaVersion"] == "9.9.9"
    assert store.db.execute("SELECT COUNT(*) FROM features WHERE dtro_id = 'demo-38'").fetchone()[0] == 0


def test_full_import_retires_records_missing_from_the_extract(store):
    records = demo_records()
    initial_import(store, ListSource(records))
    report = initial_import(store, ListSource(records[1:]))
    assert report.deleted == 1
    assert store.db.execute("SELECT deleted FROM dtro_records WHERE id = 'demo-01'").fetchone()[0] == 1
    assert store.db.execute("SELECT COUNT(*) FROM features WHERE dtro_id = 'demo-01'").fetchone()[0] == 0


def test_sync_requires_a_checkpoint(store):
    with pytest.raises(RuntimeError):
        incremental_sync(store, ListSource([]))


def test_sync_applies_update_create_and_delete_events(store):
    records = demo_records()
    initial_import(store, ListSource(records[:3]))
    store.set_state(STATE_LAST_SYNC, "2026-10-01T00:00:00Z")

    updated = copy.deepcopy(records[0])
    updated["data"]["source"]["provision"][0]["provisionDescription"] = "Changed description"
    created = records[5]
    source = ListSource(
        [updated, created],
        events=[
            {"id": updated["id"], "eventType": "update", "eventTime": "2026-10-01T10:00:00"},
            {"id": created["id"], "eventType": "create", "eventTime": "2026-10-01T11:00:00"},
            {"id": records[1]["id"], "eventType": "delete", "eventTime": "2026-10-01T12:00:00"},
        ],
    )
    report = incremental_sync(store, source, now="2026-10-02T00:00:00Z")
    assert (report.updated, report.created, report.deleted, report.failed) == (1, 1, 1, 0)
    data = store.db.execute("SELECT data FROM features WHERE dtro_id = ?", (updated["id"],)).fetchone()[0]
    assert json.loads(data)["desc"] == "Changed description"
    assert store.db.execute("SELECT deleted FROM dtro_records WHERE id = ?", (records[1]["id"],)).fetchone()[0] == 1
    assert store.db.execute("SELECT COUNT(*) FROM features WHERE dtro_id = ?", (records[1]["id"],)).fetchone()[0] == 0
    assert store.get_state(STATE_LAST_SYNC) == "2026-10-02T00:00:00Z"

    again = incremental_sync(store, source, now="2026-10-02T00:05:00Z")
    assert (again.updated, again.created, again.failed) == (0, 0, 0)


def test_sync_uses_only_the_latest_event_per_record(store):
    records = demo_records()
    initial_import(store, ListSource(records[:1]))
    store.set_state(STATE_LAST_SYNC, "2026-10-01T00:00:00Z")
    source = ListSource(
        [records[0]],
        events=[
            {"id": "demo-01", "eventType": "delete", "eventTime": "2026-10-01T09:00:00"},
            {"id": "demo-01", "eventType": "update", "eventTime": "2026-10-01T10:00:00"},
        ],
    )
    report = incremental_sync(store, source, now="2026-10-02T00:00:00Z")
    assert report.deleted == 0
    assert store.db.execute("SELECT deleted FROM dtro_records WHERE id = 'demo-01'").fetchone()[0] == 0


def test_failed_event_does_not_advance_the_checkpoint(store):
    records = demo_records()
    initial_import(store, ListSource(records[:1]))
    store.set_state(STATE_LAST_SYNC, "2026-10-01T00:00:00Z")

    class Failing(ListSource):
        def get_record(self, dtro_id):
            raise ConnectionError("service unavailable")

    source = Failing([], events=[{"id": "demo-01", "eventType": "update", "eventTime": "2026-10-01T10:00:00"}])
    report = incremental_sync(store, source, now="2026-10-02T00:00:00Z")
    assert report.failed == 1
    assert store.get_state(STATE_LAST_SYNC) == "2026-10-01T00:00:00Z"


def test_reparse_rebuilds_features_from_raw_payloads(store):
    initial_import(store, DemoDTROSource())
    before = feature_count(store)
    store.db.execute("DELETE FROM features")
    counts = store.reparse_all()
    assert feature_count(store) == before
    assert counts["unsupported"] == 1


def test_migrations_are_recorded(tmp_path):
    path = tmp_path / "locis.sqlite"
    Store(path).close()
    reopened = Store(path)
    assert reopened.db.execute("PRAGMA user_version").fetchone()[0] == len(MIGRATIONS)


def test_fixture_source_serves_records_and_events(tmp_path):
    records = demo_records()
    (tmp_path / "demo-01.json").write_text(json.dumps(records[0]))
    (tmp_path / "events").mkdir()
    (tmp_path / "events" / "day1.json").write_text(
        json.dumps([{"id": "demo-02", "eventType": "create", "eventTime": "2026-10-01T10:00:00", "record": records[1]}])
    )
    source = FixtureDTROSource(tmp_path)
    assert [r["id"] for r in source.iter_all_records()] == ["demo-01"]
    assert len(list(source.iter_events("2026-10-01T00:00:00", "2026-10-02T00:00:00"))) == 1
    assert source.get_record("demo-02")["id"] == "demo-02"
    assert source.get_record("missing") is None


# --- bulk extract decoding ---------------------------------------------------------


def _csv(rows, header):
    import csv

    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=header)
    writer.writeheader()
    writer.writerows(rows)
    return buffer.getvalue()


def test_csv_extract_with_data_column(tmp_path):
    record = demo_records()[0]
    text = _csv(
        [{"id": record["id"], "schema_version": "4.0.0", "created": "2026-09-01T09:00:00", "data": json.dumps(record["data"])}],
        ["id", "schema_version", "created", "data"],
    )
    path = tmp_path / "extract.csv"
    path.write_text(text)
    rows = list(iter_extract(path))
    assert rows[0]["id"] == "demo-01" and rows[0]["schemaVersion"] == "4.0.0"
    assert rows[0]["data"]["source"]["reference"] == "DEMO-01"


def test_csv_extract_with_whole_envelope_in_one_column():
    record = demo_records()[0]
    envelope = envelope_from_row({"Payload": json.dumps(record)})
    assert envelope["id"] == "demo-01" and "source" in envelope["data"]


def test_csv_row_without_json_is_skipped():
    assert envelope_from_row({"id": "x", "data": "not json"}) is None


def test_json_array_ndjson_and_zip_extracts(tmp_path):
    records = demo_records()[:3]
    array = tmp_path / "a.json"
    array.write_text(json.dumps(records))
    assert [r["id"] for r in iter_extract(array)] == [r["id"] for r in records]
    ndjson = tmp_path / "b.ndjson"
    ndjson.write_text("\n".join(json.dumps(r) for r in records))
    assert len(list(iter_extract(ndjson))) == 3
    archive = tmp_path / "c.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("part1.json", json.dumps(records[:2]))
        z.writestr("part2.json", json.dumps(records[2:]))
    assert len(list(iter_extract(archive))) == 3


def test_default_paths_do_not_depend_on_the_working_directory(tmp_path, monkeypatch):
    from locis_pipeline.config import load_settings, pipeline_dir

    for name in ("LOCIS_DB", "LOCIS_OUT", "LOCIS_REGION", "LOCIS_FIXTURES_DIR"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.chdir(tmp_path)
    settings = load_settings()
    assert settings.db_path == pipeline_dir() / "var" / "locis.sqlite"
    assert settings.out_dir == pipeline_dir() / "dist"
    assert settings.region is not None and settings.region[0] < -0.4  # Greater London by default


def test_region_setting(monkeypatch):
    from locis_pipeline.config import load_settings

    monkeypatch.setenv("LOCIS_REGION", "all")
    assert load_settings().region is None
    monkeypatch.setenv("LOCIS_REGION", "-0.2,51.4,0.0,51.6")
    assert load_settings().region == (-0.2, 51.4, 0.0, 51.6)
    monkeypatch.setenv("LOCIS_REGION", "1,2,3")
    with pytest.raises(ValueError):
        load_settings()
