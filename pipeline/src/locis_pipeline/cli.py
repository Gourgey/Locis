"""Command-line interface: ``locis <command>``.

    locis demo             build the synthetic demo dataset (no credentials needed)
    locis import           initial import of every published D-TRO
    locis sync             apply changes since the last import/sync
    locis update           sync if a checkpoint exists, otherwise import
    locis build            write manifest + tiles from the store
    locis publish          update, then build (what the scheduled job runs)
    locis reparse          re-run the parser over stored raw payloads
    locis status           show store counts and checkpoints
    locis inspect-extract  download the bulk extract and show its layout
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from datetime import date
from pathlib import Path

from .config import Settings, load_settings
from .demo import DemoDTROSource
from .geo import ensure_ostn15
from .dtro_client import DTROSource, FixtureDTROSource, LiveDTROSource, iter_extract
from .ingest import STATE_LAST_SYNC, incremental_sync, initial_import
from .store import Store
from .tiles import build_dataset

DEMO_GENERATED_AT = "2026-10-01T00:00:00Z"


def _source(settings: Settings) -> DTROSource:
    if settings.fixtures_dir is not None:
        return FixtureDTROSource(settings.fixtures_dir)
    if not settings.has_credentials:
        raise SystemExit(
            "No D-TRO credentials. Set DTRO_CLIENT_ID and DTRO_CLIENT_SECRET in .env "
            "(see .env.example), or run `locis demo` to build the synthetic dataset."
        )
    return LiveDTROSource(settings.base_url, settings.client_id, settings.client_secret)


def _print(value) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def cmd_demo(args, settings: Settings) -> int:
    out = Path(args.out) if args.out else settings.out_dir
    store = Store(":memory:")
    report = initial_import(store, DemoDTROSource())
    # Fixed timestamps so the bundled demo data only changes when the scenarios do.
    for key in ("last_full_import", STATE_LAST_SYNC):
        store.set_state(key, DEMO_GENERATED_AT)
    manifest = build_dataset(
        store, out, zoom=settings.tile_zoom, region=None, dataset="demo", synthetic=True,
        fetch_holidays=False, today=date(2026, 10, 1), generated_at=DEMO_GENERATED_AT,
    )
    _print({"import": report.as_dict(), "counts": manifest["counts"], "out": str(out)})
    return 0


def cmd_import(args, settings: Settings) -> int:
    store = Store(settings.db_path)
    report = initial_import(store, _source(settings))
    _print(report.as_dict())
    return 1 if report.failed else 0


def cmd_sync(args, settings: Settings) -> int:
    store = Store(settings.db_path)
    report = incremental_sync(store, _source(settings))
    _print(report.as_dict())
    return 1 if report.failed else 0


def cmd_update(args, settings: Settings) -> int:
    store = Store(settings.db_path)
    if store.get_state(STATE_LAST_SYNC) is None or args.full:
        report = initial_import(store, _source(settings))
    else:
        report = incremental_sync(store, _source(settings))
    _print(report.as_dict())
    return 1 if report.failed else 0


def cmd_build(args, settings: Settings) -> int:
    store = Store(settings.db_path)
    out = Path(args.out) if args.out else settings.out_dir
    manifest = build_dataset(store, out, zoom=settings.tile_zoom, region=settings.region, dataset="live")
    _print({"counts": manifest["counts"], "out": str(out), "holidays": manifest["holidays"]["source"]})
    return 0


def cmd_publish(args, settings: Settings) -> int:
    status = cmd_update(args, settings)
    if status != 0:
        # Do not publish over good data after a failed sync.
        print("update failed; not rebuilding tiles", file=sys.stderr)
        return status
    return cmd_build(args, settings)


def cmd_reparse(args, settings: Settings) -> int:
    _print(Store(settings.db_path).reparse_all())
    return 0


def cmd_status(args, settings: Settings) -> int:
    store = Store(settings.db_path)
    _print(
        {
            "database": str(settings.db_path),
            "lastFullImport": store.get_state("last_full_import"),
            "lastSuccessfulSync": store.get_state(STATE_LAST_SYNC),
            "importProgress": store.get_state("import_progress"),
            "counts": store.counts(),
            "credentialsConfigured": settings.has_credentials,
            "baseUrl": settings.base_url,
        }
    )
    return 0


def cmd_inspect_extract(args, settings: Settings) -> int:
    source = _source(settings)
    if not isinstance(source, LiveDTROSource):
        raise SystemExit("inspect-extract needs live credentials")
    with tempfile.TemporaryDirectory() as tmp:
        path = source.download_extract(Path(tmp) / "dtro-extract")
        with open(path, "rb") as handle:
            head = handle.read(600)
        usable = sum(1 for _ in zip(range(200), iter_extract(path)))
        _print(
            {
                "bytes": path.stat().st_size,
                "startsWith": head.decode("utf-8", "replace"),
                "recordsDecodedFromFirst200": usable,
            }
        )
    return 0


COMMANDS = {
    "demo": cmd_demo,
    "import": cmd_import,
    "sync": cmd_sync,
    "update": cmd_update,
    "build": cmd_build,
    "publish": cmd_publish,
    "reparse": cmd_reparse,
    "status": cmd_status,
    "inspect-extract": cmd_inspect_extract,
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="locis", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=sorted(COMMANDS))
    parser.add_argument("--out", help="output directory for manifest and tiles")
    parser.add_argument("--full", action="store_true", help="force a full import instead of a sync")
    args = parser.parse_args(argv)
    if args.command not in ("status",) and not ensure_ostn15():
        print("warning: OSTN15 grid unavailable; coordinates use the 2 m Helmert fallback", file=sys.stderr)
    return COMMANDS[args.command](args, load_settings())


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
