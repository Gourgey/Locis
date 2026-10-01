"""Access to the D-TRO service, behind one small interface.

Everything that knows about D-TRO endpoints lives in this module, so a change to
the service only needs a change here. ``FixtureDTROSource`` implements the same
interface from local files for tests and for working without credentials.

API facts (D-TRO API v1.6.1, checked 2026-10-01, see docs/DTRO.md):

* ``POST /oauth-generator``  client-credentials grant via HTTP basic auth; the
  access token lasts 30 minutes.
* ``GET /dtros/all``         returns a signed URL (valid 60 minutes) to a .csv
  extract of every published D-TRO.
* ``POST /events``           create/update/delete events; paginated per D-TRO.
* ``GET /dtros/{id}``        one full record.
"""

from __future__ import annotations

import csv
import io
import json
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Iterator, Protocol

import httpx

EVENT_PAGE_SIZE = 50
_EPOCH = "2020-01-01T00:00:00"


class DTROSource(Protocol):
    def iter_all_records(self) -> Iterator[dict]:
        """Yield every published D-TRO as a record envelope."""

    def iter_events(self, since: str, until: str) -> Iterator[dict]:
        """Yield change events ``{"id", "eventType", "eventTime"}`` in a window."""

    def get_record(self, dtro_id: str) -> dict | None:
        """Return one record envelope, or None if it no longer exists."""


class DTROError(RuntimeError):
    pass


# --- extract decoding ---------------------------------------------------------------


def _lower_keys(row: dict) -> dict:
    return {str(k).strip().lower().replace("_", ""): v for k, v in row.items() if k is not None}


def envelope_from_row(row: dict) -> dict | None:
    """Build a record envelope from one row of the bulk CSV extract.

    The extract's column layout is not published, so this accepts the plausible
    variants: a column holding the D-TRO JSON (``data``/``payload``/...), which may
    be the bare data object or a whole envelope, plus id/schema/timestamp columns.
    Returns None for a row with no usable JSON. Run ``locis inspect-extract`` on
    the first real download to confirm the layout.
    """
    lowered = _lower_keys(row)
    payload = None
    for key in ("data", "payload", "dtro", "json", "content", "body"):
        text = lowered.get(key)
        if isinstance(text, str) and text.lstrip().startswith("{"):
            try:
                payload = json.loads(text)
                break
            except json.JSONDecodeError:
                continue
    if payload is None:
        for text in lowered.values():
            if isinstance(text, str) and text.lstrip().startswith("{") and '"source"' in text:
                try:
                    payload = json.loads(text)
                    break
                except json.JSONDecodeError:
                    continue
    if not isinstance(payload, dict):
        return None
    if "data" in payload and "source" not in payload and "consultation" not in payload:
        envelope = dict(payload)  # the column held a whole envelope
    else:
        envelope = {"data": payload}

    def first(*names: str):
        for name in names:
            value = lowered.get(name)
            if value not in (None, ""):
                return value
        return None

    envelope.setdefault("id", first("id", "dtroid", "uuid"))
    envelope.setdefault("schemaVersion", first("schemaversion", "schema"))
    envelope.setdefault("created", first("created", "createdat", "publicationtime"))
    envelope.setdefault("lastUpdated", first("lastupdated", "updated", "modified", "lastupdateddate"))
    envelope.setdefault("traName", first("traname", "authority"))
    return envelope if envelope.get("id") else None


def iter_extract(path: Path) -> Iterator[dict]:
    """Stream record envelopes from a downloaded extract without loading it whole.

    Handles CSV (the documented format), a zip of CSV/JSON files, newline-delimited
    JSON, and a JSON array.
    """
    with open(path, "rb") as handle:
        head = handle.read(4)
    if head[:2] == b"PK":
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                with archive.open(name) as member:
                    text = io.TextIOWrapper(member, encoding="utf-8-sig", newline="")
                    yield from _iter_text(text, name)
        return
    with open(path, "r", encoding="utf-8-sig", newline="") as text:
        yield from _iter_text(text, path.name)


def _iter_text(text, name: str) -> Iterator[dict]:
    first = text.read(1)
    while first and first.isspace():
        first = text.read(1)
    if not first:
        return
    if first == "[":
        yield from _iter_json_array(text)
    elif first == "{":
        yield from _iter_ndjson(text, first)
    else:
        csv.field_size_limit(sys.maxsize)
        reader = csv.DictReader(_Prepend(first, text))
        for row in reader:
            envelope = envelope_from_row(row)
            if envelope is not None:
                yield envelope


class _Prepend:
    """Re-attach an already-read first character to a text stream for csv."""

    def __init__(self, first: str, stream):
        self._first, self._stream = first, stream

    def __iter__(self):
        return self

    def __next__(self) -> str:
        line = self._stream.readline()
        if self._first is not None:
            line, self._first = self._first + line, None
        if not line:
            raise StopIteration
        return line


def _iter_ndjson(text, first: str) -> Iterator[dict]:
    line = first + text.readline()
    while line:
        line = line.strip()
        if line:
            yield json.loads(line)
        line = text.readline()


def _iter_json_array(text, chunk_size: int = 1 << 16) -> Iterator[dict]:
    """Incrementally decode a top-level JSON array of objects."""
    decoder = json.JSONDecoder()
    buffer = ""
    while True:
        chunk = text.read(chunk_size)
        buffer += chunk
        while True:
            buffer = buffer.lstrip(" \t\r\n,")
            if not buffer or buffer[0] == "]":
                break
            try:
                value, end = decoder.raw_decode(buffer)
            except json.JSONDecodeError:
                break  # need more data
            buffer = buffer[end:]
            if isinstance(value, dict):
                yield value
        if not chunk:
            return


# --- live service -------------------------------------------------------------------


class LiveDTROSource:
    """The real D-TRO service."""

    def __init__(self, base_url: str, client_id: str, client_secret: str, *, timeout: float = 60.0):
        self.base_url = base_url.rstrip("/")
        self._auth = (client_id, client_secret)
        self._http = httpx.Client(timeout=timeout, follow_redirects=True)
        self._token: str | None = None
        self._token_expiry = 0.0

    def close(self) -> None:
        self._http.close()

    def _access_token(self) -> str:
        if self._token and time.monotonic() < self._token_expiry:
            return self._token
        response = self._http.post(
            f"{self.base_url}/oauth-generator",
            auth=self._auth,
            data={"grant_type": "client_credentials"},
        )
        if response.status_code != 200:
            raise DTROError(f"authentication failed (HTTP {response.status_code})")
        body = response.json()
        self._token = body["access_token"]
        lifetime = float(body.get("expires_in") or 1800)
        self._token_expiry = time.monotonic() + max(lifetime - 120, 60)
        return self._token

    def _request(self, method: str, path: str, **kwargs) -> httpx.Response:
        for attempt in range(4):
            headers = {"Authorization": f"Bearer {self._access_token()}", "Accept": "application/json"}
            try:
                response = self._http.request(method, f"{self.base_url}{path}", headers=headers, **kwargs)
            except httpx.TransportError:
                if attempt == 3:
                    raise
                time.sleep(2**attempt)
                continue
            if response.status_code == 401 and attempt < 3:
                self._token = None
                continue
            if response.status_code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(2**attempt)
                continue
            return response
        raise DTROError(f"{method} {path} failed after retries")  # pragma: no cover

    def extract_url(self) -> str:
        response = self._request("GET", "/dtros/all")
        if response.status_code != 200:
            raise DTROError(f"GET /dtros/all failed (HTTP {response.status_code})")
        text = response.text.strip()
        try:
            decoded = json.loads(text)
        except json.JSONDecodeError:
            decoded = text
        if isinstance(decoded, dict):
            decoded = decoded.get("url") or decoded.get("signedUrl") or next(
                (v for v in decoded.values() if isinstance(v, str) and v.startswith("http")), None
            )
        if not isinstance(decoded, str) or not decoded.startswith("http"):
            raise DTROError("GET /dtros/all did not return a download URL")
        return decoded

    def download_extract(self, destination: Path) -> Path:
        """Stream the bulk extract to disk (it is never held in memory)."""
        url = self.extract_url()
        with self._http.stream("GET", url) as response:  # signed URL: no bearer token
            if response.status_code != 200:
                raise DTROError(f"extract download failed (HTTP {response.status_code})")
            with open(destination, "wb") as handle:
                for chunk in response.iter_bytes(1 << 20):
                    handle.write(chunk)
        return destination

    def iter_all_records(self) -> Iterator[dict]:
        with tempfile.TemporaryDirectory() as tmp:
            path = self.download_extract(Path(tmp) / "dtro-extract")
            yield from iter_extract(path)

    def _event_pages(self, query: dict) -> Iterator[dict]:
        page = 1
        while True:
            body = {"page": page, "pageSize": EVENT_PAGE_SIZE, **query}
            response = self._request("POST", "/events", json=body)
            if response.status_code == 404:
                return
            if response.status_code != 200:
                raise DTROError(f"POST /events failed (HTTP {response.status_code})")
            events = (response.json() or {}).get("events") or []
            if not events:
                return
            yield from events
            page += 1

    def iter_events(self, since: str, until: str) -> Iterator[dict]:
        # ``since``/``to`` filter on a D-TRO's creation time, so changes to older
        # records need the separate modified/deleted windows.
        queries = (
            {"since": since, "to": until},
            {"since": _EPOCH, "to": until, "modifiedFrom": since, "modifiedTo": until},
            {"since": _EPOCH, "to": until, "deletedFrom": since, "deletedTo": until},
        )
        seen: set[tuple] = set()
        for query in queries:
            for event in self._event_pages(query):
                key = (event.get("id"), event.get("eventType"), event.get("eventTime"))
                if key not in seen:
                    seen.add(key)
                    yield event

    def get_record(self, dtro_id: str) -> dict | None:
        response = self._request("GET", f"/dtros/{dtro_id}")
        if response.status_code == 404:
            return None
        if response.status_code != 200:
            raise DTROError(f"GET /dtros/{dtro_id} failed (HTTP {response.status_code})")
        return response.json()


# --- fixtures -----------------------------------------------------------------------


class FixtureDTROSource:
    """A D-TRO source backed by a directory of JSON files.

    ``<dir>/*.json`` are record envelopes (the file stem is used as the id when the
    envelope has none). An optional ``<dir>/events/*.json`` holds lists of events,
    whose ``record`` key (for create/update) is the envelope to serve for that id.
    """

    def __init__(self, directory: Path):
        self.directory = Path(directory)

    def _load(self, path: Path) -> dict:
        envelope = json.loads(path.read_text(encoding="utf-8"))
        envelope.setdefault("id", path.stem)
        return envelope

    def iter_all_records(self) -> Iterator[dict]:
        for path in sorted(self.directory.glob("*.json")):
            yield self._load(path)

    def _events(self) -> list[dict]:
        events: list[dict] = []
        for path in sorted((self.directory / "events").glob("*.json")):
            events.extend(json.loads(path.read_text(encoding="utf-8")))
        return events

    def iter_events(self, since: str, until: str) -> Iterator[dict]:
        for event in self._events():
            if since <= event.get("eventTime", "") <= until:
                yield event

    def get_record(self, dtro_id: str) -> dict | None:
        latest = None
        for event in self._events():
            if event.get("id") == dtro_id and "record" in event:
                latest = event["record"]
        if latest is not None:
            return latest
        path = self.directory / f"{dtro_id}.json"
        return self._load(path) if path.is_file() else None
