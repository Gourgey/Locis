"""Spatial relationships between features, computed in metres on BNG geometry.

The rules engine needs to know which other provisions cover the same piece of
kerb (a pay bay and a peak-hour no-waiting restriction, a bay and its suspension)
and which zones a kerb lies in. Working that out needs geometry, so it is done
here and published as id lists on each feature:

``related``  provisions covering the same kerb, evaluated together with it
``partial``  the subset of ``related`` that cover only part of its length
``zones``    contextual zones (CPZ, RPZ, permit area) it lies in

Lines digitised on the same kerb are matched within a small tolerance. A line on
the road centreline carries no side-of-road information, so it is matched to
kerbs on both sides using a wider tolerance: that is deliberately conservative.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from shapely import STRtree
from shapely.geometry.base import BaseGeometry

from . import regulations as reg

KERB_TOLERANCE_M = 2.5
CENTRELINE_TOLERANCE_M = 9.0
MIN_OVERLAP_M = 5.0
MIN_OVERLAP_FRACTION = 0.5
FULL_COVER_FRACTION = 0.9

_LINE_TYPES = ("LineString", "MultiLineString")
_AREA_TYPES = ("Polygon", "MultiPolygon")
# Roles that take part in evaluating a kerb line.
_RELATABLE_ROLES = {
    reg.PERMISSION,
    reg.PROHIBITION,
    reg.BAY_SUSPENSION,
    reg.RESTRICTION_SUSPENSION,
    reg.UNSUPPORTED,
    reg.INFO,
}


@dataclass
class FeatureGeom:
    id: str
    geometry: BaseGeometry
    role: str
    quality: str
    dtro_id: str
    provision_ref: str
    related: list[str] = field(default_factory=list)
    partial: list[str] = field(default_factory=list)
    zones: list[str] = field(default_factory=list)


def _enough(overlap: float, length: float) -> bool:
    return overlap >= min(MIN_OVERLAP_M, MIN_OVERLAP_FRACTION * length)


def compute_relations(features: list[FeatureGeom]) -> None:
    """Fill ``related``, ``partial`` and ``zones`` on every line feature in place."""
    lines = [f for f in features if f.geometry.geom_type in _LINE_TYPES and f.quality != "zoneLine"]
    areas = [f for f in features if f.geometry.geom_type in _AREA_TYPES]
    relatable = [f for f in lines if f.role in _RELATABLE_ROLES]
    line_tree = STRtree([f.geometry for f in relatable]) if relatable else None
    area_tree = STRtree([f.geometry for f in areas]) if areas else None

    for feature in lines:
        length = feature.geometry.length
        if length <= 0:
            continue
        if line_tree is not None:
            search = feature.geometry.buffer(CENTRELINE_TOLERANCE_M)
            for index in line_tree.query(search):
                other = relatable[int(index)]
                if other.id == feature.id:
                    continue
                if other.dtro_id == feature.dtro_id and other.provision_ref == feature.provision_ref:
                    continue  # another place of the same provision: same rule
                either_centreline = "centreline" in (feature.quality, other.quality)
                tolerance = CENTRELINE_TOLERANCE_M if either_centreline else KERB_TOLERANCE_M
                overlap = feature.geometry.intersection(other.geometry.buffer(tolerance)).length
                if not _enough(overlap, length):
                    continue
                feature.related.append(other.id)
                if overlap < FULL_COVER_FRACTION * length:
                    feature.partial.append(other.id)
        if area_tree is not None:
            for index in area_tree.query(feature.geometry):
                area = areas[int(index)]
                if area.id == feature.id:
                    continue
                overlap = feature.geometry.intersection(area.geometry).length
                if not _enough(overlap, length):
                    continue
                if area.role == reg.ZONE:
                    feature.zones.append(area.id)
                elif area.role in _RELATABLE_ROLES:
                    feature.related.append(area.id)
                    if overlap < FULL_COVER_FRACTION * length:
                        feature.partial.append(area.id)
        feature.related.sort()
        feature.partial.sort()
        feature.zones.sort()
