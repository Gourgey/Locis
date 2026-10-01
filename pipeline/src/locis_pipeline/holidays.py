"""Bank holidays for England and Wales.

Many orders say "except bank holidays". The app resolves those against the list
published in the manifest. The authoritative list comes from GOV.UK
(https://www.gov.uk/bank-holidays.json, Open Government Licence v3.0); when it
cannot be fetched the standard holidays are computed, which misses one-off
holidays (such as a coronation), so the manifest records which source was used.
"""

from __future__ import annotations

from datetime import date, timedelta

import httpx

GOV_UK_URL = "https://www.gov.uk/bank-holidays.json"
DIVISION = "england-and-wales"


def easter_sunday(year: int) -> date:
    """Anonymous Gregorian algorithm."""
    a = year % 19
    b, c = divmod(year, 100)
    d, e = divmod(b, 4)
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = divmod(c, 4)
    l = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * l) // 451
    month, day = divmod(h + l - 7 * m + 114, 31)
    return date(year, month, day + 1)


def _first_monday(year: int, month: int) -> date:
    d = date(year, month, 1)
    return d + timedelta(days=(7 - d.weekday()) % 7)


def _last_monday(year: int, month: int) -> date:
    d = date(year, month + 1, 1) - timedelta(days=1) if month < 12 else date(year, 12, 31)
    return d - timedelta(days=d.weekday())


def computed_holidays(year: int) -> list[date]:
    """The eight standard England and Wales bank holidays with weekend substitutes."""
    days: list[date] = []
    new_year = date(year, 1, 1)
    if new_year.weekday() >= 5:
        new_year += timedelta(days=7 - new_year.weekday())
    days.append(new_year)
    easter = easter_sunday(year)
    days += [easter - timedelta(days=2), easter + timedelta(days=1)]
    days += [_first_monday(year, 5), _last_monday(year, 5), _last_monday(year, 8)]
    christmas, boxing = date(year, 12, 25), date(year, 12, 26)
    weekday = christmas.weekday()
    if weekday == 4:  # Friday: Boxing Day falls on Saturday
        boxing = date(year, 12, 28)
    elif weekday == 5:  # Saturday and Sunday
        christmas, boxing = date(year, 12, 27), date(year, 12, 28)
    elif weekday == 6:  # Sunday: Boxing Day is the Monday
        christmas = date(year, 12, 27)
    days += [christmas, boxing]
    return sorted(days)


def good_fridays(first_year: int, last_year: int) -> list[str]:
    return [(easter_sunday(y) - timedelta(days=2)).isoformat() for y in range(first_year, last_year + 1)]


def bank_holidays(today: date | None = None, *, fetch: bool = True) -> dict:
    """Return the manifest ``holidays`` block.

    ``from``/``to`` bound the dates for which the list is complete; the rules
    engine refuses to resolve "bank holiday" conditions outside that range.
    """
    today = today or date.today()
    if fetch:
        try:
            response = httpx.get(GOV_UK_URL, timeout=20.0, follow_redirects=True)
            response.raise_for_status()
            events = response.json()[DIVISION]["events"]
            dates = sorted({e["date"] for e in events if e.get("date")})
            in_range = [d for d in dates if d >= f"{today.year - 1}-01-01"]
            if in_range:
                # GOV.UK publishes complete years only.
                return {
                    "division": DIVISION,
                    "source": "gov.uk",
                    "from": f"{in_range[0][:4]}-01-01",
                    "to": f"{in_range[-1][:4]}-12-31",
                    "dates": in_range,
                    "goodFridays": good_fridays(int(in_range[0][:4]), int(in_range[-1][:4])),
                }
        except Exception:
            pass
    first, last = today.year - 1, today.year + 2
    dates = [d.isoformat() for year in range(first, last + 1) for d in computed_holidays(year)]
    return {
        "division": DIVISION,
        "source": "computed",
        "from": f"{first}-01-01",
        "to": f"{last}-12-31",
        "dates": dates,
        "goodFridays": good_fridays(first, last),
    }
