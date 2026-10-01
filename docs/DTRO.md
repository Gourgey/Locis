# D-TRO: source, licence, and how Locis uses it

Checked against the official documentation on **1 October 2026**. D-TRO is still in
beta and changes often, so re-check before relying on anything here.

## Source

The Department for Transport's Digital Traffic Regulation Order service holds traffic
orders published by traffic regulation authorities (or their software suppliers).

| | |
|---|---|
| Documentation portal | <https://d-tro.dft.gov.uk> |
| Schema, examples, release notes | <https://github.com/department-for-transport-public/D-TRO> |
| Production API | `https://dtro.dft.gov.uk/v1` |
| Integration (test data) API | `https://dtro-integration.dft.gov.uk/v1` |
| Register (production) | <https://dtro-ui.dft.gov.uk> |

Status at the time of writing:

- Public beta since 24 September 2025.
- **Data model v4.0.0** live in production since 29 May 2026. v3.5.0 and v3.5.1 are
  still supported; v3.4.x was deprecated on 1 June 2026. A v5.0.0 is being drafted.
- **API v1.6.1** (14 September 2026). v1.6.0 added spatial search.
- The regulations that would require authorities to publish to D-TRO had not been
  laid before Parliament according to DfT's repository README. **Coverage is
  therefore partial and uneven.** Real London coverage has not been measured yet
  because that needs credentials; `locis status` and the manifest's `authorities`
  list show it once data is imported.

## Licence

D-TRO data is published under the Open Government Licence v3.0. The app shows the
required attribution in About / Data Sources, and the manifest carries it:

> Contains public sector information licensed under the Open Government Licence v3.0.

Consumer access is free after registration. Consumer accounts are reviewed by a DfT
operator before first login.

Bank holiday dates come from GOV.UK (`https://www.gov.uk/bank-holidays.json`), also
OGL v3.0. The OSTN15 transformation grid is Ordnance Survey open data distributed
for PROJ.

## API used (all in `dtro_client.py`)

| Call | Use |
|---|---|
| `POST /oauth-generator` | Client-credentials grant with HTTP basic auth. Access token lasts 30 minutes; refreshed automatically |
| `GET /dtros/all` | Returns a signed URL, valid 60 minutes, for a **.csv** extract of every published D-TRO |
| `POST /events` | Create, update and delete events. Paginated per D-TRO; `totalCount` is always -1, so pages are read until one is empty |
| `GET /dtros/{id}` | One full record: `{id, schemaVersion, data, traName, created, lastUpdated}` |

`since`/`to` on `/events` filter on a record's creation time, so the sync asks three
questions per window: created since, modified since (`modifiedFrom`), and deleted
since (`deletedFrom`).

The spatial `/search` (`geometry` in WKT, BNG) is not used: a search result is a
summary, so every hit would need a further request, and the bulk extract plus events
is cheaper and complete.

## Data model as Locis reads it

A record's `data.source` has `provision[]`. Each provision has `regulatedPlace[]`
(where) and one `regulation` (what and when).

- **Where:** exactly one of `linearGeometry`, `polygon`, `pointGeometry`,
  `directedLinear`, each a WKT string prefixed `SRID=27700;` (OSGB36 / British
  National Grid). Linear geometry has `lateralPosition` (`onKerb`, `near`, `far`,
  `centreline`) and `representation` (`linear` or `representingZone`).
- **What:** `generalRegulation.regulationType` (one of about 75 values),
  `offListRegulation` (free text), or a speed limit.
- **When and to whom:** one `condition` or one `conditionSet`.

### Condition semantics

DfT's rule (`about_conditions_and_exclusions_updated.md` in its repository), which
the pipeline and engine follow exactly:

> A conditionSet (or a single condition) attached to a regulation evaluates to true
> exactly for the population of road users to whom that regulation's stated effect
> applies.

This does not vary by regulation type. An exemption is written by negating the
exempt case (`negate: true`) and combining with `and`. Operators are `and`, `or`
and `xOr` (exactly one).

### v4.0.0 versus v3.5.x

| | v3.5.x | v4.0.0 |
|---|---|---|
| `regulation` | array of one | object |
| `condition` | array of one | object |
| `conditionSet` | array of objects where `operator`, `conditions`, `condition` and a nested `conditionSet` sit side by side | object with `operator` and `conditions`; nesting only inside `conditions` |
| `maxStayNoReturn` | on `timeValidity` | on each `period` |

`parsers/v4.py` and `parsers/v35.py` hold only these differences. An unknown schema
version is stored with `parse_status = unsupported` and publishes nothing.

To add a version: write an adapter with `regulation()` and `condition_tree()`,
register it, add fixtures and tests.

## Which regulations are used

`regulations.py` lists every parking-relevant `regulationType` with a role and
category. Anything not listed (speed limits, closures, weight limits...) is ignored.
A free-text `offListRegulation` drawn on a kerb is kept with role `unsupported`, so
it turns the kerb unknown instead of being silently dropped.

Lifecycle:

| Source | Treatment |
|---|---|
| `permanentNoticeOfProposal` | Not published: not in force and may never be |
| `ttroTtmoNoticeOfIntention` | Published as `intended`: flags a planned restriction, never grants parking |
| `fullRevoke` / `partialRevoke` / `*Revocation` | Published as `revocation`: makes that kerb unknown |
| `comingIntoForceDate`, `actualStartOrStop`, experimental cessation | Carried through and applied by the engine |

## Ingestion

**Initial import** (`locis import`): downloads the extract to a temporary file and
streams it row by row, so it is never held in memory. Records are committed in
batches of 500 with a progress marker. Each record is stored verbatim with a content
hash; re-importing an unchanged record is a no-op. After a complete pass, records
missing from the extract are soft-deleted.

**Incremental sync** (`locis sync`): reads events from 10 minutes before the last
checkpoint, keeps the latest event per record, fetches created and updated records,
and soft-deletes deleted ones. The checkpoint only advances when every event was
applied, so a failed run is retried in full next time.

**Reparse** (`locis reparse`): re-runs the parser over stored raw payloads, so a
parser fix does not need a new download.

## Geometry

1. The EWKT is parsed strictly. Rejected: missing or wrong SRID, invalid WKT, empty
   geometry, zero-length lines, invalid polygons, coordinates outside the National
   Grid. A rejected place is recorded in the record's parse message; other places in
   the record are kept.
2. BNG geometry is kept for spatial analysis in metres.
3. Coordinates are converted to WGS84 with **OSTN15** (about 0.1 m). The grid is
   downloaded once from PROJ's CDN. Without it PROJ falls back to a Helmert
   transformation good to about 2 m, enough to put a kerb line on the wrong side of
   a narrow footway; the manifest records which was used.
4. Polygons are never turned into kerb lines. They are published as areas and the
   app shades them.
5. Overlaps are found in metres: lines on the same kerb within 2.5 m; a centreline
   line against kerbs within 9 m, because it records no side of the road.

## Known limitations

- **Extract layout unverified.** DfT documents the bulk extract as a .csv but not
  its columns. `envelope_from_row` accepts the plausible layouts; run
  `locis inspect-extract` on the first real download and adjust if needed.
- **Coverage unknown** until measured with credentials.
- **Revocations are not linked** to what they revoke; the kerb goes unknown instead.
- **Partial overlaps are applied to the whole feature.** A restriction covering part
  of a bay marks the whole bay. Conservative, and flagged in the details.
- **Not interpreted, so shown as unknown:** week-of-month rules, dawn/dusk and
  externally defined periods, market/match/school/event days, named holidays,
  dynamic regulations, placeholder TROs, vehicle dimension, weight, fuel and
  emissions conditions, free-text conditions.
- **Bank holidays** are England and Wales only.
- **Blue Badge concessions** on yellow lines and in paid bays vary by authority and
  are not applied. Only what the order encodes is used.
- **Tariffs:** D-TRO's rate model is used inconsistently (DfT's own example has
  overlapping bands). Only unambiguous structures are priced.
- **Data quality:** the engine reports what was published. A wrong or stale order
  produces a wrong answer, which is why the app always says to check the signs.
