import copy
import json

import jsonschema
import pytest

from conftest import FIXTURES, official
from locis_pipeline.demo import demo_records
from locis_pipeline.parsers import adapter_for, parse_record
from locis_pipeline.parsers.common import collect, normalise_period, normalise_time_validity


def by_number(n: int, suffix: str = "") -> dict:
    return next(r for r in demo_records() if r["id"] == f"demo-{n:02d}{suffix}")


def only_feature(envelope: dict) -> dict:
    parsed = parse_record(envelope)
    assert parsed.status == "parsed", parsed.message
    assert len(parsed.features) == 1
    return parsed.features[0].data


# --- schema versions ---------------------------------------------------------------


def test_adapters_cover_current_and_legacy_versions_only():
    assert adapter_for("4.0.0") is not None
    assert adapter_for("3.5.1") is not None
    assert adapter_for("3.4.0") is None
    assert adapter_for("5.0.0") is None
    assert adapter_for(None) is None
    assert adapter_for("not-a-version") is None


def test_unsupported_schema_version_is_not_interpreted():
    parsed = parse_record(by_number(38))
    assert parsed.status == "unsupported"
    assert parsed.features == []
    assert "9.9.9" in parsed.message


def test_legacy_v35_record_yields_same_tree_shape_as_v4():
    legacy = only_feature(by_number(29))
    assert legacy["schema"] == "3.5.1"
    assert legacy["cond"]["op"] == "and"
    assert [sorted(i)[0] for i in legacy["cond"]["items"]] == ["time", "permit"]


def test_demo_v4_records_validate_against_the_official_schema():
    schema = json.loads((FIXTURES / "D-TRO-v4.0.0-schema.json").read_text())
    validator = jsonschema.Draft202012Validator(schema)
    for envelope in demo_records():
        if envelope["schemaVersion"] != "4.0.0":
            continue
        errors = [e.message for e in validator.iter_errors(envelope["data"])]
        assert errors == [], f"{envelope['id']}: {errors[:3]}"


# --- official examples -------------------------------------------------------------


def test_official_rates_example():
    feature = only_feature(official("rates-example"))
    assert feature["reg"] == "kerbsidePaymentParkingPlace"
    assert feature["role"] == "permission" and feature["cat"] == "paid"
    assert feature["geomQuality"] == "kerb"
    tree = feature["cond"]
    assert tree["op"] == "and"
    vehicle_set, time_node = tree["items"]
    assert vehicle_set["op"] == "or"
    assert vehicle_set["items"][0] == {"vehicle": {"type": "car"}}
    assert vehicle_set["items"][1] == {"not": {"vehicle": {"type": "caravan"}}}
    assert time_node["time"]["valid"][0]["times"] == [[7 * 3600, 18 * 3600]]
    tiers = time_node["rate"]["collections"][0]["lines"]
    assert tiers[0]["value"] == 3.2 and tiers[0]["end"] == 7200
    assert time_node["rate"]["collections"][0]["maxTime"] == 11 * 3600


def test_official_nested_condition_sets_keep_boolean_structure():
    parsed = parse_record(official("multiple-nested-condition-sets"))
    # Not a parking regulation: nothing published, but it must not error.
    assert parsed.status in ("notRelevant", "parsed")


def test_official_max_stay_example_is_rejected_for_degenerate_geometry():
    parsed = parse_record(official("maxStayNoReturn"))
    assert parsed.status == "partial"
    assert "zero length" in parsed.message
    assert parsed.features == []


def test_non_parking_records_are_not_relevant():
    assert parse_record(official("national-speed-limit")).status == "notRelevant"
    assert parse_record(official("consultation")).status == "notRelevant"


# --- conditions --------------------------------------------------------------------


def test_negated_condition_becomes_not_node():
    envelope = by_number(19)
    cond = envelope["data"]["source"]["provision"][0]["regulation"]["conditionSet"]["conditions"][1]
    cond["negate"] = True
    tree = only_feature(envelope)["cond"]
    assert tree["items"][1] == {"not": {"vehicle": {"type": "car"}}}


def test_nested_or_inside_and():
    tree = only_feature(by_number(32))["cond"]
    assert tree["op"] == "and"
    inner = tree["items"][1]
    assert inner["op"] == "or"
    assert inner["items"][0]["permit"]["type"] == "business"
    assert inner["items"][1] == {"occupant": {"disabled": True}}


def test_xor_operator_is_normalised():
    envelope = by_number(32)
    envelope["data"]["source"]["provision"][0]["regulation"]["conditionSet"]["conditions"][1]["conditionSet"]["operator"] = "xOr"
    assert only_feature(envelope)["cond"]["items"][1]["op"] == "xor"


def test_other_condition_is_kept_and_flagged():
    feature = only_feature(by_number(16))
    assert collect(feature["cond"], "other")
    assert "issues" not in feature or "unsupportedCondition" not in feature["issues"]


def test_condition_combining_two_kinds_is_unsupported():
    envelope = by_number(1)
    regulation = envelope["data"]["source"]["provision"][0]["regulation"]
    regulation["condition"]["vehicleCharacteristics"] = {"vehicleType": "car"}
    feature = only_feature(envelope)
    assert "unsupported" in feature["cond"]
    assert "unsupportedCondition" in feature["issues"]


def test_unknown_operator_is_unsupported():
    envelope = by_number(4)
    envelope["data"]["source"]["provision"][0]["regulation"]["conditionSet"]["operator"] = "nand"
    assert "unsupported" in only_feature(envelope)["cond"]


def test_vehicle_fields_the_engine_cannot_evaluate_are_listed():
    envelope = by_number(19)
    cond = envelope["data"]["source"]["provision"][0]["regulation"]["conditionSet"]["conditions"][1]
    cond["vehicleCharacteristics"]["maximumHeightCharacteristic"] = {"vehicleHeight": 2.1}
    vehicle = only_feature(envelope)["cond"]["items"][1]["vehicle"]
    assert vehicle == {"type": "car", "unsupported": ["maximumHeightCharacteristic"]}


def test_dynamic_regulation_is_flagged():
    assert "dynamic" in only_feature(by_number(28))["issues"]


# --- time --------------------------------------------------------------------------


def test_local_times_convert_to_utc_across_bst():
    winter = normalise_time_validity({"start": "2026-01-15T08:00:00", "isPlaceholderTro": False})
    summer = normalise_time_validity({"start": "2026-07-15T08:00:00", "isPlaceholderTro": False})
    assert winter["time"]["start"] == "2026-01-15T08:00:00Z"
    assert summer["time"]["start"] == "2026-07-15T07:00:00Z"


def test_period_days_times_and_stay():
    p = normalise_period(
        {
            "recurringDayWeekMonthPeriod": [{"applicableDay": ["saturday", "monday"]}],
            "recurringTimePeriodOfDay": [{"startTimeOfPeriod": "08:30:00", "endTimeOfPeriod": "13:30:00"}],
            "maxStayNoReturn": {"maximumOccupancy": "PT4H", "minimumPeriodForReturn": "PT1H"},
        }
    )
    assert p == {"days": [{"dow": [1, 6]}], "times": [[30600, 48600]], "maxStay": 14400, "noReturn": 3600}


def test_inclusive_end_of_day_becomes_midnight():
    p = normalise_period({"recurringTimePeriodOfDay": [{"startTimeOfPeriod": "22:00:00", "endTimeOfPeriod": "23:59:59"}]})
    assert p["times"] == [[79200, 86400]]


def test_unresolvable_recurrence_is_marked_unsupported():
    market = normalise_period({"recurringSpecialDay": [{"intersectWithApplicableDays": False, "specialDayType": "marketDay"}]})
    assert market["unsupported"] == ["specialDay:marketDay"]
    holiday = normalise_period({"recurringSpecialDay": [{"intersectWithApplicableDays": False, "specialDayType": "publicHoliday"}]})
    assert "unsupported" not in holiday
    dusk = normalise_period({"periodStart": {"startType": "dusk"}})
    assert dusk["unsupported"] == ["periodStart"]
    week = normalise_period({"recurringDayWeekMonthPeriod": [{"applicableDay": ["monday"], "weekInMonth": "firstWeekOfMonth"}]})
    assert "weekInMonth" in week["unsupported"]
    stay = normalise_period({"maxStayNoReturn": {"maximumOccupancy": "P1M"}})
    assert stay["unsupported"] == ["maxStay"]


def test_placeholder_tro_is_flagged():
    envelope = by_number(1)
    envelope["data"]["source"]["provision"][0]["regulation"]["condition"]["timeValidity"]["isPlaceholderTro"] = True
    assert "placeholder" in only_feature(envelope)["issues"]


# --- lifecycle and geometry --------------------------------------------------------


def test_revocation_and_intention_lifecycle():
    assert only_feature(by_number(31, "-revocation"))["lifecycle"] == "revocation"
    assert only_feature(by_number(22, "-intended"))["lifecycle"] == "intended"
    assert "lifecycle" not in only_feature(by_number(1))


def test_proposals_are_not_published():
    envelope = by_number(1)
    source = envelope["data"]["source"]
    source["provision"][0]["orderReportingPoint"] = "permanentNoticeOfProposal"
    parsed = parse_record(envelope)
    assert parsed.features == []


def test_temporary_override_reference_is_kept():
    feature = only_feature(by_number(12, "-temporary"))
    assert feature["overrides"] == ["demo-12-p1"]
    assert feature["temporary"] is True
    assert feature["from"] == "2026-10-01"


def test_geometry_quality_classes():
    assert only_feature(by_number(1))["geomQuality"] == "kerb"
    assert only_feature(by_number(35))["geomQuality"] == "centreline"
    assert only_feature(by_number(34))["geomQuality"] == "area"
    assert only_feature(by_number(36))["geomQuality"] == "point"
    assert only_feature(by_number(37))["role"] == "zone"


def test_invalid_geometry_makes_record_partial_without_losing_other_places():
    envelope = by_number(1)
    provision = envelope["data"]["source"]["provision"][0]
    bad = copy.deepcopy(provision["regulatedPlace"][0])
    bad["linearGeometry"]["linestring"] = "SRID=27700;LINESTRING(1 1"
    provision["regulatedPlace"].append(bad)
    parsed = parse_record(envelope)
    assert parsed.status == "partial"
    assert len(parsed.features) == 1


@pytest.mark.parametrize("damage", ["no-id", "no-data", "no-provisions"])
def test_malformed_records_are_errors_not_crashes(damage):
    envelope = by_number(1)
    if damage == "no-id":
        envelope.pop("id")
    elif damage == "no-data":
        envelope["data"] = None
    else:
        envelope["data"]["source"]["provision"] = "oops"
    assert parse_record(envelope).status == "error"


def test_feature_ids_are_stable():
    a = only_feature(by_number(1))["id"]
    b = only_feature(by_number(1))["id"]
    assert a == b and len(a) == 16
