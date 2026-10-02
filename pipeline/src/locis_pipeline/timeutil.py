"""Date, time and duration helpers for D-TRO values."""

from __future__ import annotations

import re
from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo

LONDON = ZoneInfo("Europe/London")

_DURATION_RE = re.compile(
    r"^P(?!$)(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?"
    r"(?:T(?=\d)(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$"
)
_TIME_RE = re.compile(r"^([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9])$")


def parse_duration_seconds(text: str) -> int | None:
    """Parse an ISO 8601 duration to whole seconds.

    Returns None for durations using years or months: their length depends on the
    calendar, so they cannot be turned into a fixed stay limit reliably.
    """
    if not isinstance(text, str):
        return None
    match = _DURATION_RE.match(text.strip())
    if not match:
        return None
    years, months, weeks, days, hours, minutes, seconds = match.groups()
    if years or months:
        return None
    total = (
        int(weeks or 0) * 7 * 86400
        + int(days or 0) * 86400
        + int(hours or 0) * 3600
        + int(minutes or 0) * 60
        + float(seconds or 0)
    )
    return int(total)


def parse_time_of_day_seconds(text: str) -> int | None:
    """Parse ``HH:MM:SS`` to seconds after local midnight."""
    if not isinstance(text, str):
        return None
    match = _TIME_RE.match(text.strip())
    if not match:
        return None
    h, m, s = (int(g) for g in match.groups())
    return h * 3600 + m * 60 + s


def to_utc_iso(text: str, tz: ZoneInfo = LONDON) -> str | None:
    """Convert a D-TRO date-time to a UTC ISO 8601 string (``...Z``).

    D-TRO date-times are normally local wall-clock times with no offset; those are
    read in the regulation's time zone. Values carrying an explicit offset keep it.
    """
    if not isinstance(text, str) or not text.strip():
        return None
    raw = text.strip()
    if raw.endswith(("Z", "z")):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        # The bulk extract writes its Created / LastUpdated columns as
        # month/day/year, e.g. "04/23/2026 14:30:00".
        try:
            parsed = datetime.strptime(raw, "%m/%d/%Y %H:%M:%S")
        except ValueError:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=tz)
    return parsed.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_date(text: str) -> str | None:
    """Validate a ``YYYY-MM-DD`` date and return it unchanged, else None."""
    if not isinstance(text, str):
        return None
    try:
        return date.fromisoformat(text.strip()[:10]).isoformat()
    except ValueError:
        return None


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
