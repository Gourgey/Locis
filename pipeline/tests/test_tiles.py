import json
from datetime import date

import pytest

from locis_pipeline.demo import DemoDTROSource
from locis_pipeline.holidays import bank_holidays, computed_holidays, easter_sunday
from locis_pipeline.ingest import initial_import
from locis_pipeline.tiles import ATTRIBUTION, build_dataset


@pytest.fixture
def dataset(store, tmp_path):
    initial_import(store, DemoDTROSource())
    manifest = build_dataset(
        store, tmp_path, zoom=15, dataset="demo", synthetic=True, fetch_holidays=False, today=date(2026, 10, 1)
    )
    features = {}
    for key, digest in manifest["tiles"].items():
        x, y = key.split("/")
        tile = json.loads((tmp_path / "tiles" / "15" / x / f"{y}-{digest}.json").read_text())
        assert tile["v"] == manifest["formatVersion"]
        for f in tile["features"]:
            features[f["id"]] = f
    return manifest, features


def named(features, fragment):
    matches = [f for f in features.values() if fragment in f["name"]]
    assert len(matches) == 1, fragment
    return matches[0]


def test_manifest_carries_attribution_freshness_and_safety_fields(dataset):
    manifest, _ = dataset
    assert manifest["source"]["attribution"] == ATTRIBUTION
    assert manifest["synthetic"] is True and "notice" in manifest
    assert manifest["minEngineVersion"] >= 1
    assert manifest["lastSync"] and manifest["generatedAt"]
    assert manifest["counts"]["bySchemaVersion"]["9.9.9"] == 1
    assert manifest["holidays"]["source"] == "computed"


def test_overlapping_provisions_are_related_both_ways(dataset):
    _, features = dataset
    bay = named(features, "demo 13: paid bay")
    restriction = named(features, "demo 13: peak-hour")
    assert bay["related"] == [restriction["id"]]
    assert restriction["related"] == [bay["id"]]
    assert "partial" not in bay


def test_partial_overlap_is_recorded_on_the_longer_feature_only(dataset):
    _, features = dataset
    bay = named(features, "demo 33: bay partly")
    junction = named(features, "demo 33: junction")
    assert bay["related"] == [junction["id"]] and bay["partial"] == [junction["id"]]
    assert junction["related"] == [bay["id"]] and "partial" not in junction


def test_neighbouring_bays_on_the_same_kerb_are_not_related(dataset):
    _, features = dataset
    assert "related" not in named(features, "demo 01")
    assert "related" not in named(features, "demo 02")


def test_opposite_kerbs_are_not_related(dataset):
    _, features = dataset
    north = named(features, "demo 01")
    south = named(features, "demo 07")
    assert south["id"] not in north.get("related", [])


def test_zone_is_context_not_a_related_rule(dataset):
    _, features = dataset
    zone = named(features, "demo 37")
    bay = named(features, "demo 01")
    assert bay["zones"] == [zone["id"]]
    assert zone["id"] not in bay.get("related", [])
    assert zone["geom"]["type"] == "polygon"


def test_area_geometry_is_never_published_as_a_line(dataset):
    _, features = dataset
    area = named(features, "demo 34")
    assert area["geom"]["type"] == "polygon" and area["geomQuality"] == "area"


def test_unsupported_schema_record_is_absent_from_tiles(dataset):
    _, features = dataset
    assert not [f for f in features.values() if "demo 38" in f["name"]]


def test_coordinates_are_wgs84_in_the_demo_area(dataset):
    _, features = dataset
    lon, lat = named(features, "demo 01")["geom"]["coords"][0][0]
    assert -0.29 < lon < -0.26 and 51.43 < lat < 51.45


def test_region_filter_excludes_features_outside_it(store, tmp_path):
    initial_import(store, DemoDTROSource())
    manifest = build_dataset(store, tmp_path, region=(-0.2, 51.5, -0.1, 51.6), fetch_holidays=False)
    assert manifest["counts"]["features"] == 0 and manifest["tiles"] == {}


def test_rebuild_is_deterministic(store, tmp_path):
    initial_import(store, DemoDTROSource())
    kwargs = dict(fetch_holidays=False, today=date(2026, 10, 1), generated_at="2026-10-01T00:00:00Z")
    a = build_dataset(store, tmp_path / "a", **kwargs)
    b = build_dataset(store, tmp_path / "b", **kwargs)
    assert a["tiles"] == b["tiles"]


def test_bank_holiday_calendar():
    assert easter_sunday(2026) == date(2026, 4, 5)
    days = computed_holidays(2026)
    assert date(2026, 4, 3) in days and date(2026, 4, 6) in days  # Good Friday, Easter Monday
    assert date(2026, 12, 25) in days and date(2026, 12, 28) in days  # Boxing Day substitute
    assert date(2027, 12, 27) in computed_holidays(2027) and date(2027, 12, 28) in computed_holidays(2027)
    assert date(2028, 1, 3) in computed_holidays(2028)  # New Year's Day on a Saturday
    block = bank_holidays(date(2026, 10, 1), fetch=False)
    assert block["from"] == "2025-01-01" and block["to"] == "2028-12-31"
    assert "2026-04-03" in block["goodFridays"]


def test_context_features_are_separate_from_drawn_features(store, tmp_path):
    initial_import(store, DemoDTROSource())
    manifest = build_dataset(store, tmp_path, zoom=20, fetch_holidays=False, today=date(2026, 10, 1))
    # At zoom 20 a tile is about 24 m across, so some tiles hold part of a bay but need an
    # overlapping rule that lies wholly in a neighbouring tile.
    saw_context = False
    for key, digest in manifest["tiles"].items():
        x, y = key.split("/")
        tile = json.loads((tmp_path / "tiles" / "20" / x / f"{y}-{digest}.json").read_text())
        members = {f["id"] for f in tile["features"]}
        context = {f["id"] for f in tile["context"]}
        assert not members & context
        for feature in tile["features"]:
            for needed in feature.get("related", []) + feature.get("zones", []):
                assert needed in members | context
        saw_context = saw_context or bool(context)
    assert saw_context


def test_expired_orders_are_left_out_of_tiles(store, tmp_path):
    initial_import(store, DemoDTROSource())
    before = build_dataset(store, tmp_path / "a", fetch_holidays=False, generated_at="2026-10-01T00:00:00Z")
    # Demo 12's temporary restriction ends on 30 June 2027.
    after = build_dataset(store, tmp_path / "b", fetch_holidays=False, generated_at="2027-08-01T00:00:00Z")
    assert before["counts"]["expiredOmitted"] == 0
    assert after["counts"]["expiredOmitted"] == 1
    assert after["counts"]["features"] == before["counts"]["features"] - 1
