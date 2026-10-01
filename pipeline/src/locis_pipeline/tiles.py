"""Build the static dataset the app downloads: a manifest plus map tiles.

Layout of the output directory::

    manifest.json
    tiles/<zoom>/<x>/<y>-<hash>.json

Tile names contain a content hash, so a tile's URL never changes its content: the
app (and any CDN) can cache tiles forever and only fetches a tile again when the
manifest lists a new hash for it. See docs/TILE_FORMAT.md.
"""

from __future__ import annotations

import hashlib
import json
import shutil
from collections import defaultdict
from datetime import date
from pathlib import Path

from shapely import wkb
from shapely.geometry import box

from . import MIN_ENGINE_VERSION, TILE_FORMAT_VERSION
from .geo import geometry_to_json, tile_bounds, tiles_for_bounds, to_wgs84, transformation_name
from .holidays import bank_holidays
from .relate import FeatureGeom, compute_relations
from .store import Store
from .timeutil import utc_now_iso

ATTRIBUTION = "Contains public sector information licensed under the Open Government Licence v3.0."
# Zone polygons are context, not kerb lines: simplify them to keep tiles small.
ZONE_SIMPLIFY_M = 3.0
# A feature this large (in tiles) is not kerb-scale data; cap what it can touch.
MAX_TILES_PER_FEATURE = 400


def _intersects(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> bool:
    return not (a[2] < b[0] or a[0] > b[2] or a[3] < b[1] or a[1] > b[3])


def build_dataset(
    store: Store,
    out_dir: Path,
    *,
    zoom: int = 15,
    region: tuple[float, float, float, float] | None = None,
    dataset: str = "live",
    synthetic: bool = False,
    fetch_holidays: bool = True,
    today: date | None = None,
    generated_at: str | None = None,
) -> dict:
    """Write manifest and tiles to ``out_dir`` and return the manifest."""
    out_dir = Path(out_dir)
    tiles_dir = out_dir / "tiles"
    if tiles_dir.exists():
        shutil.rmtree(tiles_dir)
    tiles_dir.mkdir(parents=True, exist_ok=True)

    geoms: list[FeatureGeom] = []
    data_by_id: dict[str, dict] = {}
    wgs_by_id: dict[str, object] = {}
    bounds_by_id: dict[str, tuple[float, float, float, float]] = {}
    for row in store.iter_features():
        bounds = (row["west"], row["south"], row["east"], row["north"])
        if region is not None and not _intersects(bounds, region):
            continue
        data = json.loads(row["data"])
        geometry = wkb.loads(row["geometry_bng"])
        if geometry.geom_type in ("Polygon", "MultiPolygon"):
            simplified = geometry.simplify(ZONE_SIMPLIFY_M, preserve_topology=True)
            if not simplified.is_empty and simplified.is_valid:
                data["geom"] = geometry_to_json(to_wgs84(simplified))
        geoms.append(
            FeatureGeom(
                id=row["id"],
                geometry=geometry,
                role=row["role"],
                quality=data.get("geomQuality", ""),
                dtro_id=row["dtro_id"],
                provision_ref=data.get("prov", ""),
            )
        )
        data_by_id[row["id"]] = data
        wgs_by_id[row["id"]] = to_wgs84(geometry)
        bounds_by_id[row["id"]] = bounds

    compute_relations(geoms)
    for g in geoms:
        data = data_by_id[g.id]
        for key, value in (("related", g.related), ("partial", g.partial), ("zones", g.zones)):
            if value:
                data[key] = value

    # Assign features to the tiles their geometry touches.
    members: dict[tuple[int, int], set[str]] = defaultdict(set)
    for g in geoms:
        candidates = tiles_for_bounds(*bounds_by_id[g.id], zoom)
        if len(candidates) > MAX_TILES_PER_FEATURE:
            data_by_id[g.id].setdefault("issues", []).append("oversized")
            continue
        shape = wgs_by_id[g.id]
        for x, y in candidates:
            if len(candidates) == 1 or shape.intersects(box(*tile_bounds(x, y, zoom))):
                members[(x, y)].add(g.id)

    # A tile also carries whatever its features are evaluated against, so the app
    # never needs a neighbouring tile to evaluate a feature it can see.
    for ids in members.values():
        for feature_id in list(ids):
            data = data_by_id[feature_id]
            ids.update(i for i in data.get("related", []) if i in data_by_id)
            ids.update(i for i in data.get("zones", []) if i in data_by_id)

    tile_index: dict[str, str] = {}
    for (x, y), ids in sorted(members.items()):
        body = {
            "v": TILE_FORMAT_VERSION,
            "z": zoom,
            "x": x,
            "y": y,
            "features": [data_by_id[i] for i in sorted(ids)],
        }
        encoded = json.dumps(body, separators=(",", ":"), ensure_ascii=False, sort_keys=True).encode()
        digest = hashlib.sha256(encoded).hexdigest()[:12]
        path = tiles_dir / str(zoom) / str(x) / f"{y}-{digest}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(encoded)
        tile_index[f"{x}/{y}"] = digest

    authorities: dict[str, int] = defaultdict(int)
    for data in data_by_id.values():
        authorities[str(data.get("auth") or data.get("authCode") or "Unknown authority")] += 1

    all_bounds = list(bounds_by_id.values())
    counts = store.counts()
    manifest = {
        "formatVersion": TILE_FORMAT_VERSION,
        "minEngineVersion": MIN_ENGINE_VERSION,
        "dataset": dataset,
        "synthetic": synthetic,
        "generatedAt": generated_at or utc_now_iso(),
        "lastSync": store.get_state("last_successful_sync"),
        "lastFullImport": store.get_state("last_full_import"),
        "tileZoom": zoom,
        "transformation": transformation_name(),
        "bounds": [
            min(b[0] for b in all_bounds),
            min(b[1] for b in all_bounds),
            max(b[2] for b in all_bounds),
            max(b[3] for b in all_bounds),
        ]
        if all_bounds
        else None,
        "region": list(region) if region else None,
        "counts": {
            "records": counts["records"],
            "features": len(data_by_id),
            "tiles": len(tile_index),
            "byParseStatus": counts["byParseStatus"],
            "bySchemaVersion": counts["bySchemaVersion"],
        },
        "authorities": [
            {"name": name, "features": n} for name, n in sorted(authorities.items(), key=lambda kv: -kv[1])
        ],
        "holidays": bank_holidays(today, fetch=fetch_holidays),
        "source": {
            "name": "Department for Transport Digital Traffic Regulation Order (D-TRO) service",
            "url": "https://d-tro.dft.gov.uk",
            "licence": "Open Government Licence v3.0",
            "licenceUrl": "https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/",
            "attribution": ATTRIBUTION,
        },
        "tiles": tile_index,
    }
    if synthetic:
        manifest["notice"] = "Synthetic demonstration data. These are not real parking rules."
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, separators=(",", ":"), ensure_ascii=False, sort_keys=True), encoding="utf-8"
    )
    return manifest
