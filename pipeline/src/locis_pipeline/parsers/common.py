"""Schema-version-independent normalisation of D-TRO building blocks.

The output is the *normalised condition tree* published to the app (documented in
docs/TILE_FORMAT.md). Its node kinds are:

    {"op": "and"|"or"|"xor", "items": [node, ...]}
    {"not": node}
    {"time": {...}}                      timeValidity
    {"vehicle": {...}}                   vehicleCharacteristics
    {"permit": {...}}                    permitCondition
    {"driver": "<driverCharacteristics>"}
    {"occupant": {...}}
    {"access": ["<accessConditionType>", ...]}
    {"road": "<roadType>"}
    {"nonVehicular": "<type>"}
    {"other": "<free text>"}
    {"unsupported": "<reason>"}

D-TRO boolean semantics are preserved exactly: a tree is true for the population
and times to which the regulation's effect applies. Anything this module cannot
represent faithfully becomes an ``unsupported`` node (never dropped), which the
rules engine turns into an UNKNOWN result.
"""

from __future__ import annotations

from typing import Any

from ..timeutil import parse_date, parse_duration_seconds, parse_time_of_day_seconds, to_utc_iso

_DAYS = {
    "monday": 1,
    "tuesday": 2,
    "wednesday": 3,
    "thursday": 4,
    "friday": 5,
    "saturday": 6,
    "sunday": 7,
}
_MONTHS = {
    name: i + 1
    for i, name in enumerate(
        [
            "january",
            "february",
            "march",
            "april",
            "may",
            "june",
            "july",
            "august",
            "september",
            "october",
            "november",
            "december",
        ]
    )
}
_INSTANCES = {
    "firstInstance": 1,
    "secondInstance": 2,
    "thirdInstance": 3,
    "fourthInstance": 4,
    "fifthInstance": 5,
}
# Fields of vehicleCharacteristics the rules engine understands.
_VEHICLE_SUPPORTED = {"vehicleType", "vehicleUsage"}
# Special days the rules engine can resolve with a published calendar.
SUPPORTED_SPECIAL_DAYS = {"publicHoliday", "goodFriday"}

_CONDITION_KEYS = (
    "timeValidity",
    "vehicleCharacteristics",
    "permitCondition",
    "driverCondition",
    "occupantCondition",
    "accessCondition",
    "roadCondition",
    "nonVehicularRoadUserCondition",
    "otherCondition",
)


def unsupported(reason: str) -> dict:
    return {"unsupported": reason}


def normalise_max_stay(raw: Any) -> tuple[dict, list[str]]:
    """Normalise a maxStayNoReturn object to seconds. Returns (fields, problems)."""
    out: dict = {}
    problems: list[str] = []
    if not isinstance(raw, dict):
        return out, problems
    if "maximumOccupancy" in raw:
        seconds = parse_duration_seconds(raw["maximumOccupancy"])
        if seconds is None or seconds <= 0:
            problems.append("maxStay")
        else:
            out["maxStay"] = seconds
    if "minimumPeriodForReturn" in raw:
        seconds = parse_duration_seconds(raw["minimumPeriodForReturn"])
        if seconds is None or seconds <= 0:
            problems.append("noReturn")
        else:
            out["noReturn"] = seconds
    return out, problems


def normalise_period(raw: Any) -> dict:
    """Normalise one validPeriod / exceptionPeriod entry.

    Unrecognised or unresolvable parts are listed under ``unsupported`` so the
    engine treats the period as "cannot tell" for the times it might cover.
    """
    if not isinstance(raw, dict):
        return {"unsupported": ["period"]}
    out: dict = {}
    problems: list[str] = []

    for src, dst in (("startOfPeriod", "from"), ("endOfPeriod", "to")):
        if src in raw:
            value = to_utc_iso(raw[src])
            if value is None:
                problems.append(src)
            else:
                out[dst] = value

    if raw.get("periodName"):
        out["name"] = str(raw["periodName"])

    times = []
    for item in raw.get("recurringTimePeriodOfDay") or []:
        start = parse_time_of_day_seconds((item or {}).get("startTimeOfPeriod"))
        end = parse_time_of_day_seconds((item or {}).get("endTimeOfPeriod"))
        if start is None or end is None:
            problems.append("recurringTimePeriodOfDay")
            continue
        # Publishers write inclusive ends such as 23:59:59 or 17:59:59.
        if end % 60 == 59:
            end += 1
        times.append([start, end])
    if times:
        out["times"] = times

    days = []
    for item in raw.get("recurringDayWeekMonthPeriod") or []:
        if not isinstance(item, dict):
            problems.append("recurringDayWeekMonthPeriod")
            continue
        rule: dict = {}
        if "applicableDay" in item:
            dow = sorted({_DAYS[d] for d in item["applicableDay"] if d in _DAYS})
            if len(dow) != len(set(item["applicableDay"])):
                problems.append("applicableDay")
            rule["dow"] = dow
        if "applicableMonth" in item:
            months = sorted({_MONTHS[m] for m in item["applicableMonth"] if m in _MONTHS})
            if len(months) != len(set(item["applicableMonth"])):
                problems.append("applicableMonth")
            rule["months"] = months
        if "applicableDayWithinMonth" in item:
            rule["dom"] = sorted({int(d) for d in item["applicableDayWithinMonth"]})
        if "applicableInstanceOfDayWithinMonth" in item:
            instance = _INSTANCES.get(item["applicableInstanceOfDayWithinMonth"])
            if instance is None:
                problems.append("applicableInstanceOfDayWithinMonth")
            else:
                rule["instance"] = instance
        # Week-of-month rules depend on a week-numbering convention the data model
        # does not pin down, so they are not interpreted.
        for key in ("weekInMonth", "applicableWeek"):
            if key in item:
                problems.append(key)
        if rule:
            days.append(rule)
    if days:
        out["days"] = days

    special = []
    for item in raw.get("recurringSpecialDay") or []:
        kind = (item or {}).get("specialDayType")
        entry = {"type": kind, "intersect": bool((item or {}).get("intersectWithApplicableDays"))}
        if (item or {}).get("publicHolidayName"):
            entry["name"] = item["publicHolidayName"]
        if kind not in SUPPORTED_SPECIAL_DAYS or entry.get("name"):
            # A named holiday or a market/match/school day needs a calendar we do
            # not have.
            problems.append(f"specialDay:{kind}")
        special.append(entry)
    if special:
        out["special"] = special

    for key in ("periodStart", "periodEnd", "recurrents", "recurringPeriod"):
        if key in raw:
            problems.append(key)

    stay, stay_problems = normalise_max_stay(raw.get("maxStayNoReturn"))
    out.update(stay)
    problems.extend(stay_problems)

    if problems:
        out["unsupported"] = sorted(set(problems))
    return out


def normalise_time_validity(raw: Any) -> dict:
    """Normalise a timeValidity object to a ``{"time": {...}}`` node."""
    if not isinstance(raw, dict):
        return unsupported("timeValidity is not an object")
    time: dict = {}
    start = to_utc_iso(raw.get("start"))
    if start is None:
        return unsupported("timeValidity has no valid start")
    time["start"] = start
    if "end" in raw:
        end = to_utc_iso(raw["end"])
        if end is None:
            return unsupported("timeValidity has an invalid end")
        time["end"] = end
    if raw.get("isPlaceholderTro"):
        # A placeholder TRO stands in for an order whose real content is unknown.
        time["placeholder"] = True
    if raw.get("validPeriod"):
        time["valid"] = [normalise_period(p) for p in raw["validPeriod"]]
    if raw.get("exceptionPeriod"):
        time["except"] = [normalise_period(p) for p in raw["exceptionPeriod"]]
    # v3.5.x carried maxStayNoReturn on timeValidity itself.
    stay, problems = normalise_max_stay(raw.get("maxStayNoReturn"))
    time.update(stay)
    if problems:
        time["unsupported"] = sorted(set(problems))
    return {"time": time}


def normalise_vehicle(raw: Any) -> dict:
    if not isinstance(raw, dict) or not raw:
        return unsupported("vehicleCharacteristics is empty")
    vehicle: dict = {}
    if "vehicleType" in raw:
        vehicle["type"] = raw["vehicleType"]
    if "vehicleUsage" in raw:
        vehicle["usage"] = raw["vehicleUsage"]
    extra = sorted(k for k in raw if k not in _VEHICLE_SUPPORTED)
    if extra:
        # Dimensions, weights, fuel, emissions, extensions...: not evaluated.
        vehicle["unsupported"] = extra
    return {"vehicle": vehicle}


def normalise_permit(raw: Any) -> dict:
    if not isinstance(raw, dict):
        return unsupported("permitCondition is not an object")
    permit: dict = {"type": raw.get("type") or "other"}
    for src, dst in (
        ("schemeIdentifier", "scheme"),
        ("permitIdentifier", "identifier"),
        ("whereToApplyForPermit", "applyUrl"),
        ("whereToCallForPermit", "phone"),
    ):
        if raw.get(src):
            permit[dst] = raw[src]
    authority = raw.get("authority")
    if isinstance(authority, dict) and authority.get("name"):
        permit["authority"] = authority["name"]
    extension = raw.get("permitTypeExtension")
    if isinstance(extension, dict) and extension.get("value"):
        permit["extension"] = extension["value"]
    # D-TRO gives these two in minutes.
    if isinstance(raw.get("maximumAccessDuration"), int):
        permit["maxStay"] = raw["maximumAccessDuration"] * 60
    if isinstance(raw.get("minimumTimeToNextEntry"), int):
        permit["noReturn"] = raw["minimumTimeToNextEntry"] * 60
    return {"permit": permit}


def normalise_rate_table(raw: Any) -> dict | None:
    """Normalise a rateTable. Returns None when there is nothing usable."""
    if not isinstance(raw, dict):
        return None
    collections = []
    for coll in raw.get("rateLineCollection") or []:
        if not isinstance(coll, dict):
            continue
        entry: dict = {
            "currency": coll.get("applicableCurrency"),
            "seq": coll.get("sequence"),
        }
        for src, dst in (("startValidUsagePeriod", "from"), ("endValidUsagePeriod", "to")):
            if coll.get(src):
                entry[dst] = to_utc_iso(coll[src])
        for src, dst in (("maxTime", "maxTime"), ("minTime", "minTime")):
            if coll.get(src):
                entry[dst] = parse_duration_seconds(coll[src])
        for src, dst in (("maxValueCollection", "maxValue"), ("minValueCollection", "minValue")):
            if isinstance(coll.get(src), (int, float)):
                entry[dst] = float(coll[src])
        if coll.get("resetTime"):
            entry["resetTime"] = parse_time_of_day_seconds(coll["resetTime"])
        lines = []
        for line in coll.get("rateLine") or []:
            if not isinstance(line, dict):
                continue
            item: dict = {
                "seq": line.get("sequence"),
                "type": line.get("type"),
                "value": float(line["value"]) if isinstance(line.get("value"), (int, float)) else None,
            }
            # Durations are relative to the start of the parking session. They are
            # kept exactly as published: a band ending 01:59:59 does not include a
            # stay of exactly two hours, which belongs to the band starting 02:00:00.
            for src, dst in (("durationStart", "start"), ("durationEnd", "end")):
                if line.get(src):
                    item[dst] = parse_time_of_day_seconds(line[src])
            if isinstance(line.get("incrementPeriod"), int):
                item["increment"] = line["incrementPeriod"] * 60
            for src, dst in (("minValue", "min"), ("maxValue", "max")):
                if isinstance(line.get(src), (int, float)):
                    item[dst] = float(line[src])
            if line.get("usageCondition"):
                item["usage"] = line["usageCondition"]
            lines.append(item)
        entry["lines"] = lines
        collections.append(entry)
    if not collections:
        return None
    rate: dict = {"collections": collections}
    if raw.get("type"):
        rate["type"] = raw["type"]
    if raw.get("additionalInformation"):
        rate["info"] = raw["additionalInformation"]
    return rate


def normalise_leaf(raw: dict) -> dict:
    """Normalise the single-condition part of a D-TRO condition object.

    A condition should carry exactly one kind of condition. If a publisher supplies
    several in one object the combination is undefined by the specification, so the
    node is marked unsupported instead of guessing an operator.
    """
    present = [k for k in _CONDITION_KEYS if k in raw]
    if not present:
        return unsupported("condition has no recognised content")
    if len(present) > 1:
        return unsupported("condition combines " + "+".join(present))
    key = present[0]
    value = raw[key]
    if key == "timeValidity":
        return normalise_time_validity(value)
    if key == "vehicleCharacteristics":
        return normalise_vehicle(value)
    if key == "permitCondition":
        return normalise_permit(value)
    if key == "driverCondition":
        kind = (value or {}).get("driverCharacteristics")
        return {"driver": kind} if kind else unsupported("driverCondition is empty")
    if key == "occupantCondition":
        occupant: dict = {}
        if isinstance(value, dict):
            if "disabledWithPermit" in value:
                occupant["disabled"] = bool(value["disabledWithPermit"])
            if value.get("numberOfOccupants"):
                occupant["count"] = value["numberOfOccupants"]
        return {"occupant": occupant} if occupant else unsupported("occupantCondition is empty")
    if key == "accessCondition":
        kinds = list((value or {}).get("accessConditionType") or [])
        node: dict = {"access": kinds}
        if (value or {}).get("otherAccessRestriction"):
            node["accessOther"] = value["otherAccessRestriction"]
        return node if kinds else unsupported("accessCondition is empty")
    if key == "roadCondition":
        return {"road": (value or {}).get("roadType") or "other"}
    if key == "nonVehicularRoadUserCondition":
        return {"nonVehicular": (value or {}).get("nonVehicularRoadUser") or "other"}
    if key == "otherCondition":
        return {"other": (value or {}).get("otherConditionDescription") or ""}
    return unsupported(f"unhandled condition {key}")  # pragma: no cover


def with_modifiers(node: dict, raw: dict) -> dict:
    """Apply ``rateTable`` and ``negate`` from a raw condition to a normalised node."""
    rate = normalise_rate_table(raw.get("rateTable"))
    if rate is not None:
        node = dict(node)
        node["rate"] = rate
    elif "rateTable" in raw:
        node = dict(node)
        node["rateUnusable"] = True
    if raw.get("negate") is True:
        return {"not": node}
    return node


def collect(node: dict, key: str) -> list:
    """Collect every sub-node of a tree that has ``key``."""
    found = []
    if not isinstance(node, dict):
        return found
    if key in node:
        found.append(node)
    for item in node.get("items") or []:
        found.extend(collect(item, key))
    if "not" in node:
        found.extend(collect(node["not"], key))
    return found


def normalise_date(value: Any) -> str | None:
    return parse_date(value) if value else None
