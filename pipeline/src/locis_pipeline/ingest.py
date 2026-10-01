"""Import and synchronisation workflows.

``initial_import``   loads the complete published dataset from the bulk extract.
``incremental_sync`` applies create/update/delete events since the last checkpoint.

Both are idempotent (records are compared by content hash) and resumable: the
import commits in batches and records how far it got, and the sync only advances
its checkpoint after every event in the window has been applied.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from .dtro_client import DTROSource
from .store import Store
from .timeutil import utc_now_iso

BATCH_SIZE = 500
# Re-read a little before the checkpoint so events landing during a run are not missed.
SYNC_OVERLAP = timedelta(minutes=10)

STATE_LAST_IMPORT = "last_full_import"
STATE_LAST_SYNC = "last_successful_sync"
STATE_IMPORT_PROGRESS = "import_progress"


@dataclass
class IngestReport:
    created: int = 0
    updated: int = 0
    unchanged: int = 0
    deleted: int = 0
    failed: int = 0
    errors: list[str] = field(default_factory=list)

    def note(self, outcome: str) -> None:
        setattr(self, outcome, getattr(self, outcome) + 1)

    def as_dict(self) -> dict:
        return {
            "created": self.created,
            "updated": self.updated,
            "unchanged": self.unchanged,
            "deleted": self.deleted,
            "failed": self.failed,
            "errors": self.errors[:20],
        }


def _event_time(text: str) -> str:
    """Format a UTC timestamp the way the events endpoint expects (no offset)."""
    return text.replace("Z", "")


def initial_import(store: Store, source: DTROSource) -> IngestReport:
    """Load every published D-TRO, then retire records the extract no longer has."""
    report = IngestReport()
    started = utc_now_iso()
    seen: list[str] = []
    pending = 0
    for envelope in source.iter_all_records():
        dtro_id = str(envelope.get("id") or "")
        try:
            outcome = store.upsert_record(envelope, commit=False)
        except Exception as exc:  # keep going: one bad record must not stop the import
            report.failed += 1
            report.errors.append(f"{dtro_id or '?'}: {type(exc).__name__}: {exc}")
            continue
        seen.append(dtro_id)
        report.note(outcome)
        pending += 1
        if pending >= BATCH_SIZE:
            store.db.commit()
            store.set_state(STATE_IMPORT_PROGRESS, str(len(seen)))
            pending = 0
    store.db.commit()
    # Only a complete pass may conclude that an absent record was deleted.
    report.deleted = store.mark_missing_deleted(seen)
    store.set_state(STATE_LAST_IMPORT, started)
    store.set_state(STATE_LAST_SYNC, started)
    store.set_state(STATE_IMPORT_PROGRESS, "complete")
    return report


def incremental_sync(store: Store, source: DTROSource, *, now: str | None = None) -> IngestReport:
    """Apply change events since the last successful sync."""
    checkpoint = store.get_state(STATE_LAST_SYNC)
    if checkpoint is None:
        raise RuntimeError("no checkpoint: run the initial import first")
    until = now or utc_now_iso()
    since_dt = datetime.strptime(checkpoint, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) - SYNC_OVERLAP
    since = since_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    report = IngestReport()
    # Collapse the window to the latest event per record, applied in time order.
    latest: dict[str, dict] = {}
    for event in source.iter_events(_event_time(since), _event_time(until)):
        dtro_id = str(event.get("id") or "")
        if not dtro_id:
            continue
        current = latest.get(dtro_id)
        if current is None or str(event.get("eventTime") or "") >= str(current.get("eventTime") or ""):
            latest[dtro_id] = event

    for dtro_id, event in sorted(latest.items(), key=lambda kv: str(kv[1].get("eventTime") or "")):
        try:
            if event.get("eventType") == "delete":
                if store.mark_deleted(dtro_id, event.get("eventTime")):
                    report.deleted += 1
                else:
                    report.unchanged += 1
                continue
            envelope = source.get_record(dtro_id)
            if envelope is None:
                # Created or updated, then removed before we fetched it.
                if store.mark_deleted(dtro_id):
                    report.deleted += 1
                continue
            envelope.setdefault("id", dtro_id)
            report.note(store.upsert_record(envelope))
        except Exception as exc:
            report.failed += 1
            report.errors.append(f"{dtro_id}: {type(exc).__name__}: {exc}")

    if report.failed == 0:
        store.set_state(STATE_LAST_SYNC, until)
    return report
