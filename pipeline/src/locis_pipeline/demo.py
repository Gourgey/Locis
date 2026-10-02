"""Synthetic demonstration data.

Generates D-TRO records for a fictional street grid ("Demo Quarter") so the whole
system can be built, run and tested without D-TRO credentials. The records are
valid D-TRO v4.0.0 payloads (one is deliberately v3.5.1, one an unknown version)
and go through exactly the same parser and tile builder as live data.

NOTHING HERE IS A REAL PARKING RULE. The streets do not exist: the grid is drawn
over open parkland in Richmond Park so it cannot be mistaken for real kerbs, every
record is labelled synthetic, and the app shows a permanent demo banner.

Each scenario has a number that appears in its place name ("demo 07"); tests and
docs refer to scenarios by that number.
"""

from __future__ import annotations

import copy

# British National Grid origin of the demo grid (open ground in Richmond Park).
ORIGIN_E = 519_700.0
ORIGIN_N = 172_300.0

AUTHORITY_CODE = 9001  # the code DfT uses in its own examples
AUTHORITY_NAME = "Demo Borough (synthetic)"
TRO_PREFIX = "SYNTHETIC DEMO DATA - "
CREATED = "2026-09-01T09:00:00"
IN_FORCE = "2026-01-01"

SLOT_LENGTH = 60.0
SLOT_PITCH = 70.0
KERB_OFFSET = 4.0

STREETS = {
    "A": ("Example Street", 0.0),
    "B": ("Sample Road", 140.0),
    "C": ("Fixture Lane", 280.0),
}

MON_FRI = ["monday", "tuesday", "wednesday", "thursday", "friday"]
MON_SAT = MON_FRI + ["saturday"]
ALL_DAYS = MON_SAT + ["sunday"]


# --- geometry helpers ---------------------------------------------------------------


def _pt(x: float, y: float) -> str:
    return f"{ORIGIN_E + x:.2f} {ORIGIN_N + y:.2f}"


def slot_line(street: str, side: str, slot: int, start: float = 0.0, end: float = 1.0) -> str:
    """EWKT for (part of) one kerb slot. ``start``/``end`` are fractions of the slot."""
    y = STREETS[street][1] + (KERB_OFFSET if side == "north" else -KERB_OFFSET)
    x0 = 10.0 + (slot - 1) * SLOT_PITCH
    return f"SRID=27700;LINESTRING({_pt(x0 + SLOT_LENGTH * start, y)}, {_pt(x0 + SLOT_LENGTH * end, y)})"


def place(description: str, **geometry) -> dict:
    return {
        "description": description,
        "type": "regulationLocation",
        "assignment": False,
        "busRoute": False,
        "bywayType": "road",
        "concession": False,
        "tramcar": False,
        **geometry,
    }


def kerb(description: str, linestring: str, lateral: str = "onKerb") -> dict:
    return place(
        description,
        linearGeometry={
            "version": 1,
            "direction": "bidirectional",
            "lateralPosition": lateral,
            "linestring": linestring,
            "representation": "linear",
        },
    )


def slot_place(number: int, label: str, street: str, side: str, slot: int, **kwargs) -> dict:
    name = f"{STREETS[street][0]}, {side} side (demo {number:02d}: {label})"
    return kerb(name, slot_line(street, side, slot, **kwargs))


# --- condition helpers --------------------------------------------------------------


def period(days=None, times=None, **extra) -> dict:
    out: dict = {}
    if days:
        out["recurringDayWeekMonthPeriod"] = [{"applicableDay": list(days)}]
    if times:
        out["recurringTimePeriodOfDay"] = [
            {"startTimeOfPeriod": a, "endTimeOfPeriod": b} for a, b in times
        ]
    out.update(extra)
    return out


def time_validity(
    *periods: dict, start: str = "2026-01-01T00:00:00", end: str | None = None, exceptions=None, maxStayNoReturn=None
) -> dict:
    validity: dict = {"start": start, "isPlaceholderTro": False}
    if maxStayNoReturn:
        # A stay limit with no hours or days: carried on a period with no recurrence.
        periods = (*periods, {"maxStayNoReturn": maxStayNoReturn})
    if end:
        validity["end"] = end
    if periods:
        validity["validPeriod"] = list(periods)
    if exceptions:
        validity["exceptionPeriod"] = list(exceptions)
    return {"timeValidity": validity}


def all_of(*conditions: dict) -> dict:
    return {"conditionSet": {"operator": "and", "conditions": list(conditions)}}


def any_of(*conditions: dict) -> dict:
    return {"conditionSet": {"operator": "or", "conditions": list(conditions)}}


def stay(max_stay: str | None = None, no_return: str | None = None) -> dict:
    out = {}
    if max_stay:
        out["maximumOccupancy"] = max_stay
    if no_return:
        out["minimumPeriodForReturn"] = no_return
    return {"maxStayNoReturn": out}


def rate_per_15_minutes(value: float) -> dict:
    return {
        "type": "hourly",
        "rateLineCollection": [
            {
                "applicableCurrency": "GBP",
                "sequence": 1,
                "startValidUsagePeriod": "2026-01-01T00:00:00",
                "rateLine": [
                    {
                        "sequence": 1,
                        "type": "incrementingRate",
                        "incrementPeriod": 15,
                        "usageCondition": "unlimited",
                        "value": value,
                    }
                ],
            }
        ],
    }


def rate_tiers(*tiers: tuple[str, str, float], max_time: str | None = None) -> dict:
    collection: dict = {
        "applicableCurrency": "GBP",
        "sequence": 1,
        "startValidUsagePeriod": "2026-01-01T00:00:00",
        "rateLine": [
            {
                "sequence": i + 1,
                "type": "flatRateTier",
                "durationStart": a,
                "durationEnd": b,
                "usageCondition": "fixedDuration",
                "value": value,
            }
            for i, (a, b, value) in enumerate(tiers)
        ],
    }
    if max_time:
        collection["maxTime"] = max_time
    return {"type": "hourly", "rateLineCollection": [collection]}


# --- record helpers -----------------------------------------------------------------


def provision(
    reference: str,
    description: str,
    regulation_type: str,
    places: list[dict],
    conditions: dict,
    *,
    reporting_point: str = "permanentNoticeOfMaking",
    action: str = "new",
    in_force: str | None = IN_FORCE,
    dynamic: bool = False,
    overrides: list[str] | None = None,
) -> dict:
    regulation: dict = {
        "isDynamic": dynamic,
        "timeZone": "Europe/London",
        "generalRegulation": {"regulationType": regulation_type},
    }
    if "conditionSet" in conditions:
        regulation["conditionSet"] = conditions["conditionSet"]
    else:
        regulation["condition"] = conditions
    if overrides:
        regulation["temporaryProvision"] = [
            {"temporaryOverriddenProvision": {"reference": ref}} for ref in overrides
        ]
    out = {
        "actionType": action,
        "orderReportingPoint": reporting_point,
        "provisionDescription": description,
        "reference": reference,
        "regulatedPlace": places,
        "regulation": regulation,
    }
    if in_force:
        out["comingIntoForceDate"] = in_force
    return out


def record(
    number: int,
    name: str,
    provisions: list[dict],
    *,
    suffix: str = "",
    action: str = "new",
    in_force: str = IN_FORCE,
    schema: str = "4.0.0",
) -> dict:
    source = {
        "actionType": action,
        "currentTraOwner": AUTHORITY_CODE,
        "madeDate": "2025-12-01",
        "comingIntoForceDate": in_force,
        "reference": f"DEMO-{number:02d}{suffix}",
        "section": "Schedule 1",
        "statementDescription": "Synthetic record for demonstration and testing. Not a real order.",
        "traAffected": [AUTHORITY_CODE],
        "traCreator": AUTHORITY_CODE,
        "troName": f"{TRO_PREFIX}{name}",
        "provision": provisions,
    }
    return {
        "id": f"demo-{number:02d}{suffix}",
        "schemaVersion": schema,
        "traName": AUTHORITY_NAME,
        "created": CREATED,
        "lastUpdated": CREATED,
        "data": {"source": source},
    }


def simple(number: int, label: str, regulation_type: str, street: str, side: str, slot: int, conditions: dict, **kwargs) -> dict:
    """One record holding one provision on one kerb slot."""
    return record(
        number,
        f"{label} order",
        [
            provision(
                f"demo-{number:02d}-p1",
                f"{label}, {STREETS[street][0]}",
                regulation_type,
                [slot_place(number, label, street, side, slot)],
                conditions,
                **kwargs,
            )
        ],
    )


# --- scenarios ----------------------------------------------------------------------


def demo_records() -> list[dict]:
    """Return every synthetic D-TRO record, in a stable order."""
    always = time_validity()
    records: list[dict] = []

    # 01 Free bay, no restriction at any time.
    records.append(simple(1, "free bay", "kerbsideParkingPlace", "A", "north", 1, always))

    # 02 Paid bay whose charging hours end part-way through Saturday, with a tariff,
    #    a maximum stay and a no-return period.
    paid_hours = time_validity(
        period(MON_FRI, [("08:30:00", "18:30:00")], **stay("PT4H", "PT1H")),
        period(["saturday"], [("08:30:00", "13:30:00")], **stay("PT4H", "PT1H")),
    )
    paid_hours["rateTable"] = rate_per_15_minutes(1.20)
    records.append(simple(2, "paid bay with tariff", "kerbsidePaymentParkingPlace", "A", "north", 2, paid_hours))

    # 03 Paid bay with no tariff data.
    records.append(
        simple(
            3, "paid bay, no tariff data", "kerbsidePaymentParkingPlace", "A", "north", 3,
            time_validity(period(MON_SAT, [("08:30:00", "18:30:00")])),
        )
    )

    # 04 Resident permit bay.
    records.append(
        simple(
            4, "resident permit bay", "kerbsidePermitParkingPlace", "A", "north", 4,
            all_of(
                time_validity(period(MON_FRI, [("08:30:00", "18:30:00")])),
                {"permitCondition": {"type": "resident", "schemeIdentifier": "Zone D"}},
            ),
        )
    )

    # 05 Limited waiting: free, 2 hours, no return within 1 hour.
    records.append(
        simple(
            5, "limited waiting 2 hours", "kerbsideLimitedWaiting", "A", "north", 5,
            time_validity(period(MON_SAT, [("08:00:00", "18:00:00")], **stay("PT2H", "PT1H"))),
        )
    )

    # 06 No waiting at any time (double yellow lines).
    records.append(simple(6, "no waiting at any time", "kerbsideNoWaiting", "A", "north", 6, always))

    # 07 No waiting during the day (single yellow line).
    records.append(
        simple(
            7, "no waiting Mon-Sat daytime", "kerbsideNoWaiting", "A", "south", 1,
            time_validity(period(MON_SAT, [("08:00:00", "18:30:00")])),
        )
    )

    # 08 Disabled bay, maximum stay 3 hours.
    records.append(
        simple(
            8, "disabled bay", "kerbsideDisabledBadgeHoldersOnly", "A", "south", 2,
            time_validity(period(ALL_DAYS, None, **stay("PT3H", "PT1H"))),
        )
    )

    # 09 Loading bay.
    records.append(
        simple(
            9, "loading bay", "kerbsideLoadingBay", "A", "south", 3,
            time_validity(period(MON_SAT, [("07:00:00", "19:00:00")])),
        )
    )

    # 10 Motorcycle bay.
    records.append(simple(10, "motorcycle bay", "kerbsideMotorcycleParkingPlace", "A", "south", 4, always))

    # 11 Paid bay with tiered tariff, suspended every Wednesday for a market.
    tiered = time_validity(period(ALL_DAYS, [("08:00:00", "20:00:00")], **stay("PT4H")))
    tiered["rateTable"] = rate_tiers(
        ("00:00:00", "00:59:59", 2.50), ("01:00:00", "01:59:59", 4.50), ("02:00:00", "03:59:59", 8.00),
        max_time="PT4H",
    )
    records.append(simple(11, "paid bay, suspended Wednesdays", "kerbsidePaymentParkingPlace", "A", "south", 5, tiered))
    records.append(
        record(
            11, "bay suspension (market) order", suffix="-suspension",
            provisions=[
                provision(
                    "demo-11-suspension-p1", "Bays suspended on Wednesdays for the street market",
                    "miscBaySuspension",
                    [slot_place(11, "market-day suspension", "A", "south", 5)],
                    time_validity(period(["wednesday"], [("06:00:00", "20:00:00")])),
                    reporting_point="ttroTtmoByNotice",
                )
            ],
        )
    )

    # 12 Free bay overridden on weekdays by a temporary restriction (street works).
    records.append(simple(12, "free bay with temporary restriction", "kerbsideParkingPlace", "A", "south", 6, always))
    records.append(
        record(
            12, "temporary waiting restriction (street works) order", suffix="-temporary",
            provisions=[
                provision(
                    "demo-12-temporary-p1", "Temporary no waiting for street works, weekdays 08:00-17:00",
                    "miscTemporaryParkingRestriction",
                    [slot_place(12, "temporary works restriction", "A", "south", 6)],
                    time_validity(
                        period(MON_FRI, [("08:00:00", "17:00:00")]),
                        start="2026-10-01T00:00:00", end="2027-06-30T23:59:59",
                    ),
                    reporting_point="ttroTtmoByNotice", in_force="2026-10-01",
                    overrides=["demo-12-p1"],
                )
            ],
        )
    )

    # 13 Overlap: paid bay with a peak-hour no-waiting restriction on the same kerb.
    peak_paid = time_validity(period(MON_SAT, [("08:30:00", "18:30:00")]))
    peak_paid["rateTable"] = rate_per_15_minutes(0.90)
    records.append(simple(13, "paid bay with peak-hour restriction", "kerbsidePaymentParkingPlace", "B", "north", 1, peak_paid))
    records.append(
        record(
            13, "peak-hour no waiting order", suffix="-peak",
            provisions=[
                provision(
                    "demo-13-peak-p1", "No waiting Monday to Friday 4pm to 7pm",
                    "kerbsideNoWaiting",
                    [slot_place(13, "peak-hour no waiting", "B", "north", 1)],
                    time_validity(period(MON_FRI, [("16:00:00", "19:00:00")])),
                )
            ],
        )
    )

    # 14 Shared use: permit holders, or anyone paying.
    records.append(
        simple(
            14, "shared-use permit bay", "kerbsidePermitParkingPlace", "B", "north", 2,
            all_of(
                time_validity(period(MON_FRI, [("08:30:00", "18:30:00")])),
                {"permitCondition": {"type": "resident", "schemeIdentifier": "Zone D"}},
            ),
        )
    )
    shared_paid = time_validity(period(MON_FRI, [("08:30:00", "18:30:00")], **stay("PT2H")))
    shared_paid["rateTable"] = rate_per_15_minutes(1.00)
    records.append(
        record(
            14, "shared-use paid bay order", suffix="-paid",
            provisions=[
                provision(
                    "demo-14-paid-p1", "Pay to park, maximum 2 hours", "kerbsidePaymentParkingPlace",
                    [slot_place(14, "shared-use paid bay", "B", "north", 2)], shared_paid,
                )
            ],
        )
    )

    # 15 Conflict the engine must not resolve: a disabled bay recorded on top of a paid bay.
    records.append(
        simple(
            15, "paid bay conflicting with disabled bay", "kerbsidePaymentParkingPlace", "B", "north", 3,
            time_validity(period(MON_SAT, [("08:30:00", "18:30:00")])),
        )
    )
    records.append(
        record(
            15, "disabled bay order (conflicting)", suffix="-disabled",
            provisions=[
                provision(
                    "demo-15-disabled-p1", "Disabled badge holders only", "kerbsideDisabledBadgeHoldersOnly",
                    [slot_place(15, "conflicting disabled bay", "B", "north", 3)], always,
                )
            ],
        )
    )

    # 16 Unsupported condition: free text the engine cannot interpret.
    records.append(
        simple(
            16, "bay with uninterpretable condition", "kerbsideParkingPlace", "B", "north", 4,
            all_of(always, {"otherCondition": {"otherConditionDescription": "Except when the barrier is closed"}}),
        )
    )

    # 17 Unsupported recurrence: market days have no published calendar.
    records.append(
        simple(
            17, "paid bay on market days", "kerbsidePaymentParkingPlace", "B", "north", 5,
            time_validity(
                period(
                    None, [("08:00:00", "18:00:00")],
                    recurringSpecialDay=[{"intersectWithApplicableDays": False, "specialDayType": "marketDay"}],
                )
            ),
        )
    )

    # 18 Paid bay, except bank holidays.
    holiday_paid = time_validity(
        period(MON_SAT, [("08:30:00", "18:30:00")]),
        exceptions=[
            period(recurringSpecialDay=[{"intersectWithApplicableDays": False, "specialDayType": "publicHoliday"}])
        ],
    )
    holiday_paid["rateTable"] = rate_per_15_minutes(1.20)
    records.append(simple(18, "paid bay except bank holidays", "kerbsidePaymentParkingPlace", "B", "north", 6, holiday_paid))

    # 19 Bay for cars only.
    records.append(
        simple(
            19, "cars-only bay", "kerbsideParkingPlace", "B", "south", 1,
            all_of(always, {"vehicleCharacteristics": {"vehicleType": "car"}}),
        )
    )

    # 20 Red route, no stopping at any time.
    records.append(simple(20, "double red lines", "kerbsideDoubleRedLines", "B", "south", 2, always))

    # 21 School keep clear with two periods a day.
    records.append(
        simple(
            21, "school keep clear", "kerbsideSchoolKeepClearYellowZigZagMandatory", "B", "south", 3,
            time_validity(period(MON_FRI, [("08:00:00", "09:30:00"), ("14:30:00", "16:00:00")])),
        )
    )

    # 22 Free bay with a temporary restriction that is only a notice of intention.
    records.append(simple(22, "free bay with planned restriction", "kerbsideParkingPlace", "B", "south", 4, always))
    records.append(
        record(
            22, "notice of intention: temporary no waiting", suffix="-intended",
            provisions=[
                provision(
                    "demo-22-intended-p1", "Intended temporary no waiting (resurfacing)",
                    "miscTemporaryParkingRestriction",
                    [slot_place(22, "planned temporary restriction", "B", "south", 4)],
                    time_validity(start="2026-10-01T00:00:00", end="2027-12-31T23:59:59"),
                    reporting_point="ttroTtmoNoticeOfIntention", in_force="2026-10-01",
                )
            ],
        )
    )

    # 23 Taxi rank.
    records.append(simple(23, "taxi rank", "kerbsideTaxiRank", "B", "south", 5, always))

    # 24 Loading restriction only: says nothing about waiting.
    records.append(
        simple(
            24, "no loading only", "kerbsideNoLoading", "B", "south", 6,
            time_validity(period(MON_SAT, [("07:00:00", "19:00:00")])),
        )
    )

    # 25 Overnight restriction that crosses midnight.
    records.append(
        simple(
            25, "no waiting overnight", "kerbsideNoWaiting", "C", "north", 1,
            time_validity(period(ALL_DAYS, [("22:00:00", "23:59:59"), ("00:00:00", "06:00:00")])),
        )
    )

    # 26 Paid bay with a single daily charge.
    daily = time_validity(period(ALL_DAYS, [("00:00:00", "23:59:59")]))
    daily["rateTable"] = {
        "type": "daily",
        "rateLineCollection": [
            {
                "applicableCurrency": "GBP", "sequence": 1, "startValidUsagePeriod": "2026-01-01T00:00:00",
                "rateLine": [{"sequence": 1, "type": "flatRate", "usageCondition": "once", "value": 6.00}],
            }
        ],
    }
    records.append(simple(26, "paid bay, daily charge", "kerbsidePaymentParkingPlace", "C", "north", 2, daily))

    # 27 Short-stay limited waiting.
    records.append(
        simple(
            27, "limited waiting 30 minutes", "kerbsideLimitedWaiting", "C", "north", 3,
            time_validity(period(ALL_DAYS, [("08:00:00", "20:00:00")], **stay("PT30M", "PT2H"))),
        )
    )

    # 28 Dynamic regulation (varies by sign or system): cannot be evaluated from the order.
    records.append(simple(28, "dynamic bay", "kerbsideParkingPlace", "C", "north", 4, always, dynamic=True))

    # 29 A record in the older v3.5.1 schema.
    legacy = simple(
        29, "permit bay (legacy schema)", "kerbsidePermitParkingPlace", "C", "north", 5,
        {"placeholder": True},
    )
    legacy["schemaVersion"] = "3.5.1"
    legacy_provision = legacy["data"]["source"]["provision"][0]
    legacy_provision["regulation"] = [
        {
            "isDynamic": False,
            "timeZone": "Europe/London",
            "generalRegulation": {"regulationType": "kerbsidePermitParkingPlace"},
            "conditionSet": [
                {
                    "operator": "and",
                    "conditions": [
                        {
                            "negate": False,
                            "timeValidity": {
                                "start": "2026-01-01T00:00:00",
                                "isPlaceholderTro": False,
                                "validPeriod": [period(MON_FRI, [("08:30:00", "18:30:00")])],
                            },
                        },
                        {"negate": False, "permitCondition": {"type": "business", "schemeIdentifier": "Zone D"}},
                    ],
                }
            ],
        }
    ]
    records.append(legacy)

    # 30 An order that has not come into force yet.
    future = simple(
        30, "future paid bay", "kerbsidePaymentParkingPlace", "C", "north", 6,
        time_validity(period(MON_SAT, [("08:30:00", "18:30:00")]), start="2030-01-01T00:00:00"),
        in_force="2030-01-01",
    )
    future["data"]["source"]["comingIntoForceDate"] = "2030-01-01"
    records.append(future)

    # 31 A free bay with a later revocation recorded on the same kerb.
    records.append(simple(31, "bay with revocation on record", "kerbsideParkingPlace", "C", "south", 1, always))
    revocation = record(
        31, "revocation order", suffix="-revocation", action="fullRevoke",
        provisions=[
            provision(
                "demo-31-revocation-p1", "Revocation of parking place", "kerbsideParkingPlace",
                [slot_place(31, "revocation", "C", "south", 1)], always,
                action="fullRevoke", reporting_point="permanentRevocation", in_force="2026-06-01",
            )
        ],
    )
    records.append(revocation)

    # 32 Bay for business permit holders or Blue Badge holders (nested OR inside AND).
    records.append(
        simple(
            32, "business permit or Blue Badge bay", "kerbsidePermitParkingPlace", "C", "south", 2,
            all_of(
                time_validity(period(MON_FRI, [("08:00:00", "18:00:00")])),
                any_of(
                    {"permitCondition": {"type": "business", "schemeIdentifier": "Zone D"}},
                    {"occupantCondition": {"disabledWithPermit": True}},
                ),
            ),
        )
    )

    # 33 Free bay, part of which is covered by a no-waiting restriction.
    records.append(simple(33, "bay partly covered by a restriction", "kerbsideParkingPlace", "C", "south", 3, always))
    records.append(
        record(
            33, "junction protection order", suffix="-junction",
            provisions=[
                provision(
                    "demo-33-junction-p1", "No waiting at any time (junction protection)", "kerbsideNoWaiting",
                    [slot_place(33, "junction protection", "C", "south", 3, start=0.0, end=0.4)], always,
                )
            ],
        )
    )

    # 34 Paid parking recorded only as an area: must not be drawn as a kerb line.
    area_x0, area_x1 = 10.0 + 3 * SLOT_PITCH, 10.0 + 3 * SLOT_PITCH + SLOT_LENGTH
    area_y0, area_y1 = 280.0 - 34.0, 280.0 - 6.0
    ring = ", ".join(
        _pt(x, y)
        for x, y in [(area_x0, area_y0), (area_x1, area_y0), (area_x1, area_y1), (area_x0, area_y1), (area_x0, area_y0)]
    )
    records.append(
        record(
            34, "paid parking area order",
            provisions=[
                provision(
                    "demo-34-p1", "Paid parking area", "kerbsidePaymentParkingPlace",
                    [
                        place(
                            "Fixture Lane, south side (demo 34: paid parking recorded as an area)",
                            polygon={"version": 1, "polygon": f"SRID=27700;POLYGON(({ring}))"},
                        )
                    ],
                    time_validity(period(MON_SAT, [("08:30:00", "18:30:00")])),
                )
            ],
        )
    )

    # 35 Restriction drawn on the road centreline: which kerb it applies to is not recorded.
    records.append(
        record(
            35, "centreline no waiting order",
            provisions=[
                provision(
                    "demo-35-p1", "No waiting Monday to Saturday 8am to 6.30pm", "kerbsideNoWaiting",
                    [
                        kerb(
                            "Mock Avenue (demo 35: no waiting recorded on the centreline)",
                            f"SRID=27700;LINESTRING({_pt(-25.0, 20.0)}, {_pt(-25.0, 260.0)})",
                            lateral="centreline",
                        )
                    ],
                    time_validity(period(MON_SAT, [("08:00:00", "18:30:00")])),
                )
            ],
        )
    )

    # 36 Disabled bay recorded only as a point.
    records.append(
        record(
            36, "disabled bay (point) order",
            provisions=[
                provision(
                    "demo-36-p1", "Disabled badge holders only", "kerbsideDisabledBadgeHoldersOnly",
                    [
                        place(
                            "Placeholder Place (demo 36: disabled bay recorded as a point)",
                            pointGeometry={
                                "version": 1,
                                "point": f"SRID=27700;POINT({_pt(450.0, 70.0)})",
                                "representation": "other",
                            },
                        )
                    ],
                    always,
                )
            ],
        )
    )

    # 37 Controlled parking zone covering the whole quarter (context only).
    zone_ring = ", ".join(
        _pt(x, y) for x, y in [(-45.0, -30.0), (470.0, -30.0), (470.0, 310.0), (-45.0, 310.0), (-45.0, -30.0)]
    )
    records.append(
        record(
            37, "controlled parking zone D order",
            provisions=[
                provision(
                    "demo-37-p1", "Controlled Parking Zone D, Monday to Friday 8.30am to 6.30pm",
                    "kerbsideControlledParkingZone",
                    [
                        place(
                            "Zone D (demo 37: controlled parking zone)",
                            polygon={"version": 1, "polygon": f"SRID=27700;POLYGON(({zone_ring}))"},
                        )
                    ],
                    time_validity(period(MON_FRI, [("08:30:00", "18:30:00")])),
                )
            ],
        )
    )

    # 39 A real-world publishing habit: "No stopping except buses" written with the
    #    plain condition "bus", which literally restricts only buses.
    records.append(
        simple(
            39, "bus stop published the wrong way round", "kerbsideNoStopping", "C", "south", 6,
            all_of(always, {"vehicleCharacteristics": {"vehicleType": "bus"}}),
        )
    )
    records[-1]["data"]["source"]["provision"][0]["provisionDescription"] = "No stopping except buses"

    # 40 Another real-world habit: "No waiting at any time" with its exemptions
    #    attached as OR(NOT(any vehicle), Blue Badge up to 3 hours, loading up to 40 minutes).
    exemption_list = any_of(
        {"negate": True, "vehicleCharacteristics": {"vehicleType": "anyVehicle"}},
        all_of({"occupantCondition": {"disabledWithPermit": True}}, time_validity(**stay("PT3H"))),
        all_of({"accessCondition": {"accessConditionType": ["loadingAndUnloading"]}}, time_validity(**stay("PT40M"))),
    )
    records.append(
        record(
            40, "no waiting with an exemption list order",
            provisions=[
                provision(
                    "demo-40-p1", "No waiting at any time", "kerbsideNoWaiting",
                    [
                        kerb(
                            "Placeholder Place, east side (demo 40: no waiting with an exemption list)",
                            f"SRID=27700;LINESTRING({_pt(444.0, 100.0)}, {_pt(444.0, 160.0)})",
                        )
                    ],
                    all_of(always, exemption_list),
                )
            ],
        )
    )

    # 41 A bay for electric vehicles.
    records.append(
        record(
            41, "electric vehicle bay order",
            provisions=[
                provision(
                    "demo-41-p1", "Electric vehicle charging bay, maximum stay 3 hours", "kerbsideParkingPlace",
                    [
                        kerb(
                            "Placeholder Place, east side (demo 41: electric vehicle bay)",
                            f"SRID=27700;LINESTRING({_pt(444.0, 170.0)}, {_pt(444.0, 230.0)})",
                        )
                    ],
                    all_of(
                        time_validity(period(ALL_DAYS, None, **stay("PT3H"))),
                        {"vehicleCharacteristics": {"fuelType": ["electric"]}},
                    ),
                )
            ],
        )
    )

    # 38 A record in a schema version the pipeline does not know: preserved, not published.
    unknown = copy.deepcopy(records[0])
    unknown["id"] = "demo-38"
    unknown["schemaVersion"] = "9.9.9"
    unknown["data"]["source"]["reference"] = "DEMO-38"
    unknown["data"]["source"]["provision"][0]["reference"] = "demo-38-p1"
    unknown["data"]["source"]["provision"][0]["regulatedPlace"] = [
        slot_place(38, "record in an unknown schema version", "C", "south", 5)
    ]
    records.append(unknown)

    return records


class DemoDTROSource:
    """The synthetic records behind the same interface as the live service."""

    def iter_all_records(self):
        yield from demo_records()

    def iter_events(self, since: str, until: str):
        return iter(())

    def get_record(self, dtro_id: str):
        return next((r for r in demo_records() if r["id"] == dtro_id), None)
