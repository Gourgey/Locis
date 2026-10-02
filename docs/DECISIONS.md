# Decisions that changed the brief

The original brief is in [BRIEF.md](BRIEF.md). These decisions were made with the
project owner on 1 October 2026 and take precedence over it.

## 1. No server: static tiles and an on-device rules engine

**Brief:** a FastAPI + PostgreSQL/PostGIS backend evaluates rules and serves an API
(sections 14, 16, 19).

**Decision:** there is no running backend. A scheduled job runs the Python pipeline
and publishes static files (a manifest and map tiles). The app downloads the tiles
for the visible area and evaluates the stay on the phone, in Swift.

**Why:** the project exists to avoid a monthly fee. A hosted API and database either
cost money or depend on free tiers that sleep and change terms. Static files are
free to host, need no upkeep, and have a privacy benefit: the map position and
chosen times never leave the phone.

**What it changes:**

| Brief | Now |
|---|---|
| Rules engine in Python, tested with pytest | Rules engine in Swift (`ios/LocisKit`), tested with Swift Testing |
| PostgreSQL + PostGIS | SQLite working store in the pipeline; spatial work with Shapely + STRtree |
| FastAPI `/v1/parking/segments` | `manifest.json` + `tiles/<z>/<x>/<y>-<hash>.json` ([TILE_FORMAT.md](TILE_FORMAT.md)) |
| `GET /v1/data/status` | The manifest: last sync, counts, schema versions |
| `docker compose up` | Nothing to start; `scripts/setup.sh` creates the Python environment |
| Database migrations (Alembic) | Versioned migrations in `store.py` |

Everything else in the brief stands: D-TRO adapter boundary, raw payload retention,
resumable import, incremental sync, versioned parsers, demo mode, confidence, and
the safety rules.

**Cost of the decision:** a fix to the rules engine reaches users through an App
Store update, not instantly. Mitigation: the manifest carries `minEngineVersion`.
If the published data needs newer logic than an installed app has, that app shows a
notice and draws nothing, instead of interpreting data it may misread.

## 2. The app is called Locis

**Brief:** working name "Parking".

**Decision:** the owner named the project and App Store record "Locis"
(bundle id `studio.curateddesign.Locis`). The display name is still one setting,
`LOCIS_DISPLAY_NAME`.

## 3. Minimum iOS version is 18

Everything the app uses has been available since iOS 17. Requiring iOS 26 would
exclude users for no gain.

## 4. D-TRO v3.5.x records are parsed too

**Brief:** support v4.0.0.

**Decision:** the service still accepts v3.5.0 and v3.5.1, and v4.0.0 only went
live on 29 May 2026, so much published data is likely to be v3.5.x. A second
adapter reads it. Its sibling-nested condition sets were described by DfT as
ambiguous, so those features are flagged and capped at medium confidence.

## 5. Kerbs with no line get a note, never a colour

A council only makes a traffic order where it restricts something, so an ordinary
unrestricted kerb has no record. In the data that looks exactly like a kerb whose
orders have not been published, and the app cannot tell the two apart.

**Decision:** such a kerb is never drawn and never given a status. Where every
map tile on screen has data and they average at least 40 kerb rules each
(`ParkingMapModel.denseRulesPerTile`), the map shows "No line: no restriction
recorded. Check signs." Elsewhere the key keeps "No line means no data, not free
parking." Measured on live data, councils that have published their whole network
(Barnet, Redbridge) have a median of about 100 rules per tile; those that have
published a handful of orders have under 10. The note is text only: it changes
no evaluation.
