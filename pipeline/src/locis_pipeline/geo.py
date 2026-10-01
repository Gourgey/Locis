"""Geometry handling: D-TRO EWKT (EPSG:27700) parsing, validation and conversion to WGS84.

D-TRO geometries are WKT strings prefixed with ``SRID=27700;`` (OSGB36 / British
National Grid). MapKit needs WGS84 (EPSG:4326), so everything published to the app
is converted here. The original BNG geometry is kept for spatial analysis in metres.
"""

from __future__ import annotations

import math
import os
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import pyproj
from pyproj import Transformer
from pyproj.transformer import TransformerGroup
from shapely import wkt as shapely_wkt
from shapely.errors import ShapelyError
from shapely.geometry.base import BaseGeometry
from shapely.ops import transform as shapely_transform

BNG_SRID = 27700

# Generous envelope of valid British National Grid coordinates (metres).
_BNG_MIN_E, _BNG_MAX_E = -100_000.0, 800_000.0
_BNG_MIN_N, _BNG_MAX_N = -100_000.0, 1_400_000.0

_EWKT_RE = re.compile(r"^\s*SRID\s*=\s*(\d+)\s*;\s*(.+?)\s*$", re.IGNORECASE | re.DOTALL)

SUPPORTED_GEOMETRY_TYPES = {
    "Point",
    "MultiPoint",
    "LineString",
    "MultiLineString",
    "Polygon",
    "MultiPolygon",
}


class GeometryError(ValueError):
    """Raised when a source geometry cannot be used."""


@dataclass(frozen=True)
class SourceGeometry:
    """A parsed D-TRO geometry in its source CRS (BNG)."""

    geometry: BaseGeometry
    srid: int

    @property
    def geometry_type(self) -> str:
        return self.geometry.geom_type


def parse_ewkt(text: str) -> SourceGeometry:
    """Parse a D-TRO ``SRID=27700;...`` WKT string.

    Raises GeometryError for anything that is not valid, non-empty BNG geometry of
    a supported type. Nothing is repaired silently: a bad geometry is a data-quality
    problem that must surface, not be drawn.
    """
    if not isinstance(text, str) or not text.strip():
        raise GeometryError("geometry is empty")
    match = _EWKT_RE.match(text)
    if not match:
        raise GeometryError("geometry has no SRID prefix")
    srid = int(match.group(1))
    if srid != BNG_SRID:
        raise GeometryError(f"unsupported SRID {srid} (expected {BNG_SRID})")
    try:
        geometry = shapely_wkt.loads(match.group(2))
    except (ShapelyError, ValueError) as exc:
        raise GeometryError(f"invalid WKT: {exc}") from exc
    if geometry.is_empty:
        raise GeometryError("geometry is empty")
    if geometry.geom_type not in SUPPORTED_GEOMETRY_TYPES:
        raise GeometryError(f"unsupported geometry type {geometry.geom_type}")
    if geometry.has_z:
        geometry = shapely_transform(lambda x, y, z=None: (x, y), geometry)
    min_e, min_n, max_e, max_n = geometry.bounds
    if not all(math.isfinite(v) for v in (min_e, min_n, max_e, max_n)):
        raise GeometryError("geometry has non-finite coordinates")
    if min_e < _BNG_MIN_E or max_e > _BNG_MAX_E or min_n < _BNG_MIN_N or max_n > _BNG_MAX_N:
        raise GeometryError("coordinates are outside the British National Grid")
    if geometry.geom_type in ("LineString", "MultiLineString") and geometry.length <= 0:
        raise GeometryError("line has zero length")
    if geometry.geom_type in ("Polygon", "MultiPolygon"):
        if not geometry.is_valid:
            raise GeometryError("polygon is not valid")
        if geometry.area <= 0:
            raise GeometryError("polygon has zero area")
    return SourceGeometry(geometry=geometry, srid=srid)


OSTN15_GRID = "uk_os_OSTN15_NTv2_OSGBtoETRS.tif"
OSTN15_URL = f"https://cdn.proj.org/{OSTN15_GRID}"


def ensure_ostn15(download: bool = True) -> bool:
    """Make Ordnance Survey's OSTN15 grid available to PROJ. Returns True if it is.

    OSTN15 is the definitive OSGB36 <-> ETRS89 transformation (about 0.1 m). Without
    it PROJ falls back to a Helmert transformation that is only good to about 2 m,
    which is enough to put a kerb line on the wrong side of a narrow footway. The
    grid is open data, published for PROJ at cdn.proj.org.
    """
    if any((Path(d) / OSTN15_GRID).is_file() for d in _proj_data_dirs()):
        return True
    if not download or os.environ.get("LOCIS_OFFLINE"):
        return False
    import httpx

    target_dir = Path(pyproj.datadir.get_user_data_dir(create=True))
    target = target_dir / OSTN15_GRID
    partial = target.with_suffix(".part")
    try:
        with httpx.stream("GET", OSTN15_URL, timeout=120.0, follow_redirects=True) as response:
            response.raise_for_status()
            with open(partial, "wb") as handle:
                for chunk in response.iter_bytes(1 << 20):
                    handle.write(chunk)
        partial.replace(target)
    except Exception:
        partial.unlink(missing_ok=True)
        return False
    _to_wgs84.cache_clear()
    _to_bng.cache_clear()
    return True


def _proj_data_dirs() -> list[str]:
    dirs = [pyproj.datadir.get_user_data_dir(), pyproj.datadir.get_data_dir()]
    return [d for part in dirs for d in str(part).split(os.pathsep) if d]


def transformation_name() -> str:
    """Describe the BNG -> WGS84 transformation in use, for the manifest."""
    return "OSTN15" if ensure_ostn15(download=False) else "Helmert (about 2 m)"


def _best_transformer(source: int, target: int) -> Transformer:
    # always_xy: (easting, northing) <-> (longitude, latitude).
    group = TransformerGroup(source, target, always_xy=True)
    return group.transformers[0]


@lru_cache(maxsize=1)
def _to_wgs84() -> Transformer:
    return _best_transformer(BNG_SRID, 4326)


@lru_cache(maxsize=1)
def _to_bng() -> Transformer:
    return _best_transformer(4326, BNG_SRID)


def bng_to_wgs84(easting: float, northing: float) -> tuple[float, float]:
    """Return (longitude, latitude) for a BNG coordinate."""
    lon, lat = _to_wgs84().transform(easting, northing)
    return lon, lat


def wgs84_to_bng(lon: float, lat: float) -> tuple[float, float]:
    """Return (easting, northing) for a WGS84 coordinate."""
    e, n = _to_bng().transform(lon, lat)
    return e, n


def to_wgs84(geometry: BaseGeometry) -> BaseGeometry:
    """Reproject a BNG geometry to WGS84 (x = longitude, y = latitude)."""
    return shapely_transform(_to_wgs84().transform, geometry)


def _round_coords(coords, places: int = 6) -> list[list[float]]:
    out: list[list[float]] = []
    for x, y in coords:
        pt = [round(x, places), round(y, places)]
        if not out or out[-1] != pt:
            out.append(pt)
    return out


def geometry_to_json(geometry: BaseGeometry) -> dict:
    """Encode a WGS84 geometry in the compact form used in tiles.

    ``{"type": "line", "coords": [[[lon, lat], ...], ...]}``: lines are always a list
    of parts so LINESTRING and MULTILINESTRING share one shape. Polygons are a list
    of polygons, each a list of rings (outer first). Points are a list of positions.
    """
    kind = geometry.geom_type
    if kind == "LineString":
        return {"type": "line", "coords": [_round_coords(geometry.coords)]}
    if kind == "MultiLineString":
        return {"type": "line", "coords": [_round_coords(g.coords) for g in geometry.geoms]}
    if kind == "Polygon":
        return {"type": "polygon", "coords": [_polygon_rings(geometry)]}
    if kind == "MultiPolygon":
        return {"type": "polygon", "coords": [_polygon_rings(g) for g in geometry.geoms]}
    if kind == "Point":
        return {"type": "point", "coords": _round_coords(geometry.coords)}
    if kind == "MultiPoint":
        return {"type": "point", "coords": _round_coords([g.coords[0] for g in geometry.geoms])}
    raise GeometryError(f"unsupported geometry type {kind}")


def _polygon_rings(polygon) -> list[list[list[float]]]:
    rings = [_round_coords(polygon.exterior.coords)]
    rings.extend(_round_coords(r.coords) for r in polygon.interiors)
    return rings


# --- Slippy-map tile maths (Web Mercator XYZ scheme) ---------------------------------


def tile_for(lon: float, lat: float, zoom: int) -> tuple[int, int]:
    """Return the (x, y) tile containing a WGS84 position."""
    lat = max(min(lat, 85.05112878), -85.05112878)
    n = 1 << zoom
    x = int((lon + 180.0) / 360.0 * n)
    lat_rad = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return min(max(x, 0), n - 1), min(max(y, 0), n - 1)


def tile_bounds(x: int, y: int, zoom: int) -> tuple[float, float, float, float]:
    """Return (west, south, east, north) of a tile in WGS84 degrees."""
    n = 1 << zoom
    west = x / n * 360.0 - 180.0
    east = (x + 1) / n * 360.0 - 180.0
    north = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    south = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))))
    return west, south, east, north


def tiles_for_bounds(
    west: float, south: float, east: float, north: float, zoom: int
) -> list[tuple[int, int]]:
    """Return every tile touched by a WGS84 bounding box."""
    x0, y0 = tile_for(west, north, zoom)
    x1, y1 = tile_for(east, south, zoom)
    return [(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
