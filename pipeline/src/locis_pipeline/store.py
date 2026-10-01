"""SQLite store for raw D-TRO records, normalised features and sync checkpoints.

The store is a working database for the pipeline, not something the app talks to.
Raw payloads are kept verbatim so a parsing bug can be diagnosed and fixed by
re-parsing (``locis reparse``) without downloading everything again.

Schema changes go through ``MIGRATIONS``: append a new entry, never edit an old one.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Iterable, Iterator

from shapely import wkb

from .parsers import ParsedRecord, parse_record
from .timeutil import utc_now_iso

MIGRATIONS: list[str] = [
    # 1: initial schema
    """
    CREATE TABLE dtro_records (
        id                  TEXT PRIMARY KEY,
        schema_version      TEXT,
        tra_creator         INTEGER,
        tra_owner           INTEGER,
        tra_name            TEXT,
        tro_name            TEXT,
        created_at_source   TEXT,
        modified_at_source  TEXT,
        raw_payload         TEXT NOT NULL,
        payload_hash        TEXT NOT NULL,
        imported_at         TEXT NOT NULL,
        deleted             INTEGER NOT NULL DEFAULT 0,
        deleted_at          TEXT,
        parse_status        TEXT NOT NULL,
        parse_message       TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX idx_dtro_records_status ON dtro_records (parse_status);
    CREATE INDEX idx_dtro_records_owner ON dtro_records (tra_owner);

    CREATE TABLE features (
        id               TEXT PRIMARY KEY,
        dtro_id          TEXT NOT NULL REFERENCES dtro_records (id) ON DELETE CASCADE,
        provision_ref    TEXT NOT NULL,
        regulation_type  TEXT NOT NULL,
        role             TEXT NOT NULL,
        category         TEXT NOT NULL,
        geometry_type    TEXT NOT NULL,
        geometry_bng     BLOB NOT NULL,
        west             REAL NOT NULL,
        south            REAL NOT NULL,
        east             REAL NOT NULL,
        north            REAL NOT NULL,
        data             TEXT NOT NULL
    );
    CREATE INDEX idx_features_dtro ON features (dtro_id);
    CREATE INDEX idx_features_bbox ON features (west, east, south, north);
    CREATE INDEX idx_features_regulation ON features (regulation_type);

    CREATE TABLE sync_state (
        key    TEXT PRIMARY KEY,
        value  TEXT NOT NULL
    );
    """,
]


class Store:
    def __init__(self, path: str | Path):
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.path)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.execute("PRAGMA journal_mode = WAL")
        self.migrate()

    def close(self) -> None:
        self.db.close()

    # --- migrations ---------------------------------------------------------------

    def migrate(self) -> int:
        """Apply pending migrations. Returns the resulting schema version."""
        current = self.db.execute("PRAGMA user_version").fetchone()[0]
        for number, script in enumerate(MIGRATIONS, start=1):
            if number > current:
                self.db.executescript(script)
                self.db.execute(f"PRAGMA user_version = {number}")
                self.db.commit()
        return len(MIGRATIONS)

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        try:
            yield self.db
            self.db.commit()
        except Exception:
            self.db.rollback()
            raise

    # --- checkpoints --------------------------------------------------------------

    def get_state(self, key: str, default: str | None = None) -> str | None:
        row = self.db.execute("SELECT value FROM sync_state WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default

    def set_state(self, key: str, value: str) -> None:
        self.db.execute(
            "INSERT INTO sync_state (key, value) VALUES (?, ?) "
            "ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            (key, value),
        )
        self.db.commit()

    # --- records ------------------------------------------------------------------

    @staticmethod
    def payload_hash(envelope: dict) -> str:
        canonical = json.dumps(envelope, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(canonical.encode()).hexdigest()

    def upsert_record(self, envelope: dict, *, commit: bool = True) -> str:
        """Store one D-TRO record and its features. Idempotent.

        Returns "created", "updated" or "unchanged". Re-importing an identical
        payload is a no-op, so imports and syncs can be re-run safely.
        """
        dtro_id = str(envelope.get("id") or "")
        if not dtro_id:
            raise ValueError("D-TRO record has no id")
        digest = self.payload_hash(envelope)
        existing = self.db.execute(
            "SELECT payload_hash, deleted FROM dtro_records WHERE id = ?", (dtro_id,)
        ).fetchone()
        if existing and existing["payload_hash"] == digest and not existing["deleted"]:
            return "unchanged"

        parsed = parse_record(envelope)
        source = ((envelope.get("data") or {}).get("source") or {}) if isinstance(envelope.get("data"), dict) else {}
        self.db.execute(
            """
            INSERT INTO dtro_records (id, schema_version, tra_creator, tra_owner, tra_name, tro_name,
                created_at_source, modified_at_source, raw_payload, payload_hash, imported_at,
                deleted, deleted_at, parse_status, parse_message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                schema_version = excluded.schema_version, tra_creator = excluded.tra_creator,
                tra_owner = excluded.tra_owner, tra_name = excluded.tra_name,
                tro_name = excluded.tro_name, created_at_source = excluded.created_at_source,
                modified_at_source = excluded.modified_at_source, raw_payload = excluded.raw_payload,
                payload_hash = excluded.payload_hash, imported_at = excluded.imported_at,
                deleted = 0, deleted_at = NULL, parse_status = excluded.parse_status,
                parse_message = excluded.parse_message
            """,
            (
                dtro_id,
                envelope.get("schemaVersion"),
                source.get("traCreator"),
                source.get("currentTraOwner"),
                envelope.get("traName"),
                source.get("troName"),
                envelope.get("created"),
                envelope.get("lastUpdated"),
                json.dumps(envelope, separators=(",", ":")),
                digest,
                utc_now_iso(),
                parsed.status,
                parsed.message,
            ),
        )
        self._replace_features(dtro_id, parsed)
        if commit:
            self.db.commit()
        return "updated" if existing else "created"

    def _replace_features(self, dtro_id: str, parsed: ParsedRecord) -> None:
        self.db.execute("DELETE FROM features WHERE dtro_id = ?", (dtro_id,))
        self.db.executemany(
            "INSERT OR REPLACE INTO features (id, dtro_id, provision_ref, regulation_type, role, category, "
            "geometry_type, geometry_bng, west, south, east, north, data) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    f.id,
                    dtro_id,
                    f.data["prov"],
                    f.data["reg"],
                    f.data["role"],
                    f.data["cat"],
                    f.geometry_bng.geom_type,
                    wkb.dumps(f.geometry_bng),
                    f.bounds_wgs84[0],
                    f.bounds_wgs84[1],
                    f.bounds_wgs84[2],
                    f.bounds_wgs84[3],
                    json.dumps(f.data, separators=(",", ":")),
                )
                for f in parsed.features
            ],
        )

    def mark_deleted(self, dtro_id: str, deleted_at: str | None = None, *, commit: bool = True) -> bool:
        """Soft-delete a record and drop its features. Returns False if unknown."""
        row = self.db.execute("SELECT deleted FROM dtro_records WHERE id = ?", (dtro_id,)).fetchone()
        if row is None:
            return False
        self.db.execute(
            "UPDATE dtro_records SET deleted = 1, deleted_at = ? WHERE id = ?",
            (deleted_at or utc_now_iso(), dtro_id),
        )
        self.db.execute("DELETE FROM features WHERE dtro_id = ?", (dtro_id,))
        if commit:
            self.db.commit()
        return True

    def mark_missing_deleted(self, seen_ids: Iterable[str]) -> int:
        """After a complete import, soft-delete records the extract no longer has."""
        self.db.execute("CREATE TEMP TABLE IF NOT EXISTS seen_ids (id TEXT PRIMARY KEY)")
        self.db.execute("DELETE FROM seen_ids")
        self.db.executemany("INSERT OR IGNORE INTO seen_ids (id) VALUES (?)", ((i,) for i in seen_ids))
        missing = [
            row["id"]
            for row in self.db.execute(
                "SELECT id FROM dtro_records WHERE deleted = 0 AND id NOT IN (SELECT id FROM seen_ids)"
            )
        ]
        for dtro_id in missing:
            self.mark_deleted(dtro_id, commit=False)
        self.db.commit()
        return len(missing)

    def reparse_all(self) -> dict[str, int]:
        """Re-run the parser over every stored raw payload (after a parser fix)."""
        counts: dict[str, int] = {}
        rows = self.db.execute("SELECT id, raw_payload FROM dtro_records WHERE deleted = 0").fetchall()
        for row in rows:
            parsed = parse_record(json.loads(row["raw_payload"]))
            self.db.execute(
                "UPDATE dtro_records SET parse_status = ?, parse_message = ? WHERE id = ?",
                (parsed.status, parsed.message, row["id"]),
            )
            self._replace_features(row["id"], parsed)
            counts[parsed.status] = counts.get(parsed.status, 0) + 1
        self.db.commit()
        return counts

    # --- queries ------------------------------------------------------------------

    def iter_features(self) -> Iterator[sqlite3.Row]:
        yield from self.db.execute(
            "SELECT id, dtro_id, role, category, geometry_type, geometry_bng, west, south, east, north, data "
            "FROM features ORDER BY id"
        )

    def counts(self) -> dict:
        def scalar(sql: str) -> int:
            return self.db.execute(sql).fetchone()[0]

        by_status = {
            row["parse_status"]: row["n"]
            for row in self.db.execute(
                "SELECT parse_status, COUNT(*) AS n FROM dtro_records WHERE deleted = 0 GROUP BY parse_status"
            )
        }
        by_schema = {
            str(row["schema_version"]): row["n"]
            for row in self.db.execute(
                "SELECT schema_version, COUNT(*) AS n FROM dtro_records WHERE deleted = 0 GROUP BY schema_version"
            )
        }
        return {
            "records": scalar("SELECT COUNT(*) FROM dtro_records WHERE deleted = 0"),
            "deletedRecords": scalar("SELECT COUNT(*) FROM dtro_records WHERE deleted = 1"),
            "features": scalar("SELECT COUNT(*) FROM features"),
            "byParseStatus": by_status,
            "bySchemaVersion": by_schema,
        }
