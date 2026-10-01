import math

import pytest

from locis_pipeline.geo import (
    GeometryError,
    bng_to_wgs84,
    geometry_to_json,
    parse_ewkt,
    tile_bounds,
    tile_for,
    tiles_for_bounds,
    to_wgs84,
    wgs84_to_bng,
)


def test_linestring_parses():
    g = parse_ewkt("SRID=27700;LINESTRING(530000 180000, 530100 180000)")
    assert g.geometry_type == "LineString"
    assert g.geometry.length == pytest.approx(100.0)


def test_multilinestring_parses_and_keeps_parts():
    g = parse_ewkt("SRID=27700;MULTILINESTRING((530000 180000, 530050 180000),(530060 180000, 530100 180000))")
    assert g.geometry_type == "MultiLineString"
    encoded = geometry_to_json(to_wgs84(g.geometry))
    assert encoded["type"] == "line"
    assert len(encoded["coords"]) == 2


def test_polygon_with_hole_parses():
    g = parse_ewkt(
        "SRID=27700;POLYGON((530000 180000, 530100 180000, 530100 180100, 530000 180100, 530000 180000),"
        "(530040 180040, 530060 180040, 530060 180060, 530040 180060, 530040 180040))"
    )
    encoded = geometry_to_json(to_wgs84(g.geometry))
    assert encoded["type"] == "polygon"
    assert len(encoded["coords"]) == 1 and len(encoded["coords"][0]) == 2


def test_multipolygon_and_point_parse():
    mp = parse_ewkt(
        "SRID=27700;MULTIPOLYGON(((0 0, 10 0, 10 10, 0 10, 0 0)),((20 20, 30 20, 30 30, 20 30, 20 20)))"
    )
    assert len(geometry_to_json(to_wgs84(mp.geometry))["coords"]) == 2
    pt = parse_ewkt("SRID=27700;POINT(530000 180000)")
    assert geometry_to_json(to_wgs84(pt.geometry))["type"] == "point"


def test_space_before_bracket_is_accepted():
    assert parse_ewkt("SRID=27700;LINESTRING (530000 180000, 530100 180000)").geometry_type == "LineString"


@pytest.mark.parametrize(
    "text, reason",
    [
        ("", "empty"),
        (None, "empty"),
        ("LINESTRING(530000 180000, 530100 180000)", "SRID"),
        ("SRID=4326;LINESTRING(-0.1 51.5, -0.2 51.5)", "SRID"),
        ("SRID=27700;LINESTRING(530000 180000", "invalid WKT"),
        ("SRID=27700;LINESTRING EMPTY", "empty"),
        ("SRID=27700;LINESTRING(444284 333253, 444284 333253)", "zero length"),
        ("SRID=27700;LINESTRING(-0.1 51.5, 9999999 51.5)", "outside"),
        ("SRID=27700;POLYGON((0 0, 10 10, 0 10, 10 0, 0 0))", "not valid"),
        ("SRID=27700;GEOMETRYCOLLECTION(POINT(1 1))", "unsupported geometry type"),
        ("SRID=27700;DROP TABLE features", "invalid WKT"),
    ],
)
def test_bad_geometry_is_rejected(text, reason):
    with pytest.raises(GeometryError, match=reason):
        parse_ewkt(text)


def test_bng_to_wgs84_applies_the_datum_shift():
    # Ordnance Survey's worked example, Caister water tower (TG 51409 13177), is
    # 52.657570 N, 1.717922 E on the OSGB36 datum. WGS84 differs from OSGB36 by
    # roughly 100 m here, so a correct conversion lands near, but not on, that.
    lon, lat = bng_to_wgs84(651409.903, 313177.270)
    north_m = (lat - 52.657570) * 111_320
    east_m = (lon - 1.717922) * 111_320 * math.cos(math.radians(lat))
    assert 60 < math.hypot(north_m, east_m) < 160
    assert north_m > 0 and east_m < 0  # WGS84 is north-west of OSGB36 in East Anglia


def test_bng_to_wgs84_charing_cross():
    # TQ 30030 80440, the conventional centre of London.
    lon, lat = bng_to_wgs84(530030, 180440)
    assert lat == pytest.approx(51.5079, abs=5e-4)
    assert lon == pytest.approx(-0.1277, abs=5e-4)


def test_conversion_round_trips_within_a_centimetre():
    e, n = 530123.4, 180456.7
    e2, n2 = wgs84_to_bng(*bng_to_wgs84(e, n))
    assert math.hypot(e - e2, n - n2) < 0.01


def test_tile_maths_is_consistent():
    x, y = tile_for(-0.1277, 51.5079, 15)
    west, south, east, north = tile_bounds(x, y, 15)
    assert west <= -0.1277 < east and south <= 51.5079 < north
    assert (x, y) in tiles_for_bounds(west, south, east, north, 15)
    assert len(tiles_for_bounds(-0.13, 51.50, -0.11, 51.52, 15)) >= 4
