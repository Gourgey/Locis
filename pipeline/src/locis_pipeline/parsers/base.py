"""Version-independent D-TRO record parsing.

``parse_record`` picks a schema-version adapter and turns one D-TRO record into
normalised parking features. The adapters only know how a schema version nests
regulations and conditions; everything else is shared here.

Parse statuses stored against each record:

``parsed``        every parking provision was normalised
``partial``       some provisions or places could not be used (see message)
``notRelevant``   valid record with no parking-relevant provisions
``unsupported``   schema version has no adapter: record preserved, nothing published
``error``         record is malformed
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any, Callable, Protocol
from zoneinfo import ZoneInfo

from shapely.geometry.base import BaseGeometry

from .. import regulations as reg
from ..geo import GeometryError, geometry_to_json, parse_ewkt, to_wgs84
from ..timeutil import to_utc_iso
from .common import collect, normalise_date

_GEOMETRY_KEYS = {
    "linearGeometry": "linestring",
    "polygon": "polygon",
    "pointGeometry": "point",
    "directedLinear": "directedLineString",
}
_KERB_POSITIONS = {"onKerb", "near", "far"}
# Service timestamps (created / lastUpdated) carry no offset and are UTC.
_UTC = ZoneInfo("UTC")


class SchemaAdapter(Protocol):
    """Knows the regulation/condition nesting of one family of schema versions."""

    def regulation(self, provision: dict) -> dict | None:
        """Return the provision's single regulation object, or None if unusable."""

    def condition_tree(self, regulation: dict) -> tuple[dict, list[str]]:
        """Return (normalised condition tree, issue codes)."""


@dataclass
class ParsedFeature:
    id: str
    data: dict
    geometry_bng: BaseGeometry
    bounds_wgs84: tuple[float, float, float, float]


@dataclass
class ParsedRecord:
    dtro_id: str
    schema_version: str | None
    status: str
    message: str = ""
    features: list[ParsedFeature] = field(default_factory=list)
    provisions_seen: int = 0
    provisions_relevant: int = 0


_ADAPTERS: list[tuple[Callable[[tuple[int, ...]], bool], SchemaAdapter]] = []


def register_adapter(matches: Callable[[tuple[int, ...]], bool], adapter: SchemaAdapter) -> None:
    _ADAPTERS.append((matches, adapter))


def _version_tuple(version: str | None) -> tuple[int, ...] | None:
    if not isinstance(version, str):
        return None
    try:
        return tuple(int(part) for part in version.strip().split("."))
    except ValueError:
        return None


def adapter_for(schema_version: str | None) -> SchemaAdapter | None:
    version = _version_tuple(schema_version)
    if version is None:
        return None
    for matches, adapter in _ADAPTERS:
        if matches(version):
            return adapter
    return None


def feature_id(dtro_id: str, provision_reference: str, place_index: int) -> str:
    """Stable identifier for one regulated place of one provision."""
    digest = hashlib.sha1(f"{dtro_id}|{provision_reference}|{place_index}".encode()).hexdigest()
    return digest[:16]


def _lifecycle(source: dict, provision: dict) -> str | None:
    """Classify where a provision is in its legal life. None means in force."""
    point = provision.get("orderReportingPoint")
    if point == "permanentNoticeOfProposal":
        return "proposal"
    if (
        source.get("actionType") == "fullRevoke"
        or provision.get("actionType") in reg.REVOKING_ACTION_TYPES
        or point in reg.REVOCATION_REPORTING_POINTS
    ):
        return "revocation"
    if point == "ttroTtmoNoticeOfIntention":
        return "intended"
    return None


def _geometry_quality(key: str, geometry: dict) -> str:
    if key == "polygon":
        return "area"
    if key == "pointGeometry":
        return "point"
    if key == "directedLinear":
        return "centreline"
    if geometry.get("representation") == "representingZone":
        return "zoneLine"
    return "kerb" if geometry.get("lateralPosition") in _KERB_POSITIONS else "centreline"


def parse_record(envelope: dict) -> ParsedRecord:
    """Parse one D-TRO record as returned by the D-TRO service.

    ``envelope`` is ``{"id", "schemaVersion", "data": {"source": {...}}, ...}``.
    """
    dtro_id = str(envelope.get("id") or "")
    schema_version = envelope.get("schemaVersion")
    if not dtro_id:
        return ParsedRecord(dtro_id, schema_version, "error", "record has no id")
    adapter = adapter_for(schema_version)
    if adapter is None:
        return ParsedRecord(
            dtro_id, schema_version, "unsupported", f"no parser for schema version {schema_version!r}"
        )
    data = envelope.get("data")
    if not isinstance(data, dict):
        return ParsedRecord(dtro_id, schema_version, "error", "record has no data object")
    if "consultation" in data and "source" not in data:
        return ParsedRecord(dtro_id, schema_version, "notRelevant", "consultation record")
    source = data.get("source")
    if not isinstance(source, dict) or not isinstance(source.get("provision"), list):
        return ParsedRecord(dtro_id, schema_version, "error", "record has no source.provision list")

    record = ParsedRecord(dtro_id, schema_version, "parsed")
    problems: list[str] = []
    authority_name = envelope.get("traName")
    updated = to_utc_iso(str(envelope.get("lastUpdated") or ""), tz=_UTC) if envelope.get("lastUpdated") else None
    published = to_utc_iso(str(envelope.get("created") or ""), tz=_UTC) if envelope.get("created") else None

    for index, provision in enumerate(source["provision"]):
        record.provisions_seen += 1
        if not isinstance(provision, dict):
            problems.append(f"provision {index}: not an object")
            continue
        regulation = adapter.regulation(provision)
        if regulation is None:
            problems.append(f"provision {index}: regulation missing or ambiguous")
            continue
        try:
            features = _provision_features(
                adapter, dtro_id, schema_version, source, provision, regulation,
                authority_name, updated, published, problems, index,
            )
        except Exception as exc:  # one bad provision must not lose the rest
            problems.append(f"provision {index}: {type(exc).__name__}: {exc}")
            continue
        if features is None:
            continue
        record.provisions_relevant += 1
        record.features.extend(features)

    if problems:
        record.status = "partial"
        record.message = "; ".join(problems[:20])
    elif record.provisions_relevant == 0:
        record.status = "notRelevant"
    return record


def _provision_features(
    adapter: SchemaAdapter,
    dtro_id: str,
    schema_version: str,
    source: dict,
    provision: dict,
    regulation: dict,
    authority_name: str | None,
    updated: str | None,
    published: str | None,
    problems: list[str],
    index: int,
) -> list[ParsedFeature] | None:
    general = regulation.get("generalRegulation")
    off_list = regulation.get("offListRegulation")
    regulation_type = general.get("regulationType") if isinstance(general, dict) else None
    classification = reg.classify(regulation_type)
    if classification is None and not isinstance(off_list, dict):
        return None  # speed limits, closures, weight limits...: not parking

    lifecycle = _lifecycle(source, provision)
    if lifecycle == "proposal":
        return None  # not in force and may never be

    issues: list[str] = []
    if classification is None:
        # A free-text regulation: it may restrict parking but cannot be interpreted.
        role, category = reg.UNSUPPORTED, reg.OTHER
        regulation_type = "offList"
    else:
        role, category = classification

    tree, tree_issues = adapter.condition_tree(regulation)
    issues.extend(tree_issues)
    if regulation.get("isDynamic") is True:
        issues.append("dynamic")
    if regulation.get("timeZone") not in (None, "Europe/London"):
        issues.append("timeZone")
    if collect(tree, "unsupported"):
        issues.append("unsupportedCondition")
    if any(node["time"].get("placeholder") for node in collect(tree, "time")):
        issues.append("placeholder")

    overrides = []
    for temp in regulation.get("temporaryProvision") or []:
        ref = ((temp or {}).get("temporaryOverriddenProvision") or {}).get("reference")
        if ref:
            overrides.append(str(ref))

    activity = []
    for event in provision.get("actualStartOrStop") or []:
        at = to_utc_iso((event or {}).get("eventAt"))
        kind = (event or {}).get("eventType")
        if at and kind in ("start", "stop"):
            activity.append({"at": at, "type": kind})
        else:
            issues.append("actualStartOrStop")
    activity.sort(key=lambda e: e["at"])

    base: dict[str, Any] = {
        "dtro": dtro_id,
        "prov": str(provision.get("reference") or index),
        "reg": regulation_type,
        "role": role,
        "cat": category,
        "desc": provision.get("provisionDescription") or "",
        "tro": source.get("troName") or "",
        "auth": authority_name,
        "authCode": source.get("currentTraOwner"),
        "orp": provision.get("orderReportingPoint"),
        "temporary": provision.get("orderReportingPoint") in reg.TEMPORARY_REPORTING_POINTS,
        "cond": tree,
        "schema": schema_version,
    }
    if lifecycle:
        base["lifecycle"] = lifecycle
    if isinstance(off_list, dict):
        base["offList"] = {
            "name": off_list.get("regulationShortName") or "",
            "text": off_list.get("regulationFullText") or "",
        }
    in_force = normalise_date(provision.get("comingIntoForceDate") or source.get("comingIntoForceDate"))
    if in_force:
        base["from"] = in_force
    cessation = (provision.get("experimentalCessation") or {}).get("actualDateOfCessation")
    if normalise_date(cessation):
        base["until"] = normalise_date(cessation)
    if overrides:
        base["overrides"] = overrides
    if activity:
        base["activity"] = activity
    if updated:
        base["updated"] = updated
    if published:
        base["published"] = published

    features: list[ParsedFeature] = []
    for place_index, place in enumerate(provision.get("regulatedPlace") or []):
        if not isinstance(place, dict) or place.get("type") == "diversionRoute":
            continue
        geometry_key = next((k for k in _GEOMETRY_KEYS if k in place), None)
        if geometry_key is None:
            problems.append(f"provision {index} place {place_index}: no geometry")
            continue
        geometry = place[geometry_key] or {}
        quality = _geometry_quality(geometry_key, geometry)
        if classification is None and quality != "kerb":
            continue  # free-text regulations are only kept when drawn on a kerb
        try:
            parsed = parse_ewkt(geometry.get(_GEOMETRY_KEYS[geometry_key]))
        except GeometryError as exc:
            problems.append(f"provision {index} place {place_index}: {exc}")
            continue
        wgs84 = to_wgs84(parsed.geometry)
        data = dict(base)
        data["id"] = feature_id(dtro_id, base["prov"], place_index)
        data["name"] = place.get("description") or ""
        data["geom"] = geometry_to_json(wgs84)
        data["geomQuality"] = quality
        if geometry.get("lateralPosition"):
            data["lateral"] = geometry["lateralPosition"]
        usrns = sorted(
            {
                entry.get("usrn")
                for ref in geometry.get("externalReference") or []
                for entry in (ref or {}).get("uniqueStreetReferenceNumber") or []
                if isinstance(entry, dict) and entry.get("usrn") is not None
            }
        )
        if usrns:
            data["usrn"] = usrns
        if issues:
            data["issues"] = sorted(set(issues))
        features.append(ParsedFeature(data["id"], data, parsed.geometry, wgs84.bounds))
    return features

