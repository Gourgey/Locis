# Locis

A free iPhone app that answers one question for UK kerbsides, starting with London:

> Am I legally allowed to park on this section of kerb for the whole of my stay?

You search for a place or move the map, choose when you'll arrive and leave, and the
kerbs are coloured by whether parking is legal for that entire period. Tapping a line
explains the rule. The app does **not** know whether a space is empty.

No accounts, adverts, subscriptions, analytics or tracking.

Parking rules come from the Department for Transport's Digital Traffic Regulation
Order (D-TRO) service. Contains public sector information licensed under the Open
Government Licence v3.0.

## How it fits together

```
D-TRO service ──► pipeline (Python) ──► static files ──► iPhone app (Swift)
  DfT API          parse, convert,       manifest.json     downloads tiles for the
                   relate, cut tiles     + map tiles       visible map, evaluates
                                                           the stay on the device
```

There is no server. A scheduled job publishes small static files; the app downloads
the ones for the area on screen and works out legality itself. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and, for why this differs from the
original brief, [docs/DECISIONS.md](docs/DECISIONS.md).

| Folder | What it is |
|---|---|
| `pipeline/` | Python: D-TRO client, parser, geometry, tile builder, synthetic demo data |
| `ios/LocisKit/` | Swift package: data models, rules engine, data loading, map model |
| `ios/Locis/` | The SwiftUI app |
| `ios/LocisTests/` | App-level tests |
| `docs/` | Architecture, D-TRO notes, rules engine, deployment, tile format |
| `scripts/` | Setup, tests, demo data, run in Simulator |

## Prerequisites

- A Mac with Xcode 26 or later (iOS 18 is the minimum iOS version)
- Python 3.11 or later

Docker is not needed.

## Run it

The app downloads live parking data from <https://gourgey.github.io/Locis/>, which a
scheduled job republishes about every fortnight (see [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)).

For development without that data, empty `LOCIS_DATA_BASE_URL` in
`ios/Config/Locis.xcconfig` (or override it in `ios/Config/Local.xcconfig`). The app
then runs on built-in **demo data**: made-up streets drawn over parkland, clearly
labelled, so nothing can be mistaken for a real rule.

```bash
scripts/setup.sh
```

```bash
scripts/run-simulator.sh
```

Or open `ios/Locis.xcodeproj` in Xcode and press Run.

### On a physical iPhone

1. Open `ios/Locis.xcodeproj` in Xcode.
2. Select the **Locis** target, then **Signing & Capabilities**, and confirm the
   team (the project is set to team `5865Y52YG7`, bundle id `studio.curateddesign.Locis`).
3. Plug in the phone, choose it as the run destination, and press Run.

## Tests

```bash
scripts/test-all.sh
```

That runs the pipeline tests (pytest), the rules-engine tests (`swift test`, no
Simulator needed) and the app tests in the Simulator. Add `--skip-app` to skip the
Simulator part.

## Live data

Live data needs D-TRO credentials, which are free:

1. Register as a **consumer** at <https://dtro-ui.dft.gov.uk> and wait for approval.
2. Create an application in the D-TRO user portal to get a client id and secret.
3. Copy `.env.example` to `.env` and fill in `DTRO_CLIENT_ID` and `DTRO_CLIENT_SECRET`.
   `.env` is git-ignored. Never commit credentials.

Then, from the repository root:

```bash
pipeline/.venv/bin/locis inspect-extract
```

This confirms the layout of the bulk download (see "Known limitations" in
[docs/DTRO.md](docs/DTRO.md)). Then:

```bash
pipeline/.venv/bin/locis import
```

```bash
pipeline/.venv/bin/locis build
```

`import` loads every published order; `build` writes `pipeline/dist/manifest.json`
and the tiles. Afterwards `locis sync` fetches only what changed, and
`locis publish` does sync-then-build in one step.

To publish the data and point the app at it, follow
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md). In short: add the two credentials as
GitHub repository secrets, enable the scheduled workflow, and set
`LOCIS_DATA_BASE_URL` in `ios/Config/Locis.xcconfig`.

### Pipeline commands

| Command | What it does |
|---|---|
| `locis demo` | Build the synthetic demo dataset (no credentials) |
| `locis import` | Initial import of every published D-TRO |
| `locis sync` | Apply changes since the last import or sync |
| `locis update` | `sync` if a checkpoint exists, otherwise `import` |
| `locis build` | Write manifest and tiles from the local store |
| `locis publish` | `update`, then `build` |
| `locis authorities` | Look up names for authorities known only by code |
| `locis reparse` | Re-run the parser over stored raw records (after a parser fix) |
| `locis status` | Show record counts and checkpoints |
| `locis inspect-extract` | Download the bulk extract and show its layout |

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `DTRO_CLIENT_ID`, `DTRO_CLIENT_SECRET` | none | D-TRO consumer application credentials |
| `DTRO_BASE_URL` | production | `https://dtro-integration.dft.gov.uk/v1` for the test environment |
| `LOCIS_REGION` | Greater London | `west,south,east,north`, or `all` |
| `LOCIS_DB` | `pipeline/var/locis.sqlite` | Pipeline working database |
| `LOCIS_OUT` | `pipeline/dist` | Where manifest and tiles are written |
| `LOCIS_TILE_ZOOM` | `15` | Tile zoom level |
| `LOCIS_FIXTURES_DIR` | none | Read records from JSON files instead of the live service |
| `LOCIS_OFFLINE` | none | Set to `1` to stop the OSTN15 grid download |

The database schema is created and upgraded automatically by versioned migrations in
`pipeline/src/locis_pipeline/store.py`.

### Viewing real data in the Simulator

Debug builds can read tiles straight from the pipeline's output folder, without
publishing them:

```bash
SIMCTL_CHILD_LOCIS_DATA_DIR="$PWD/pipeline/dist" SIMCTL_CHILD_LOCIS_START="51.6145,-0.1755" \
    xcrun simctl launch "iPhone 17 Pro" studio.curateddesign.Locis
```

## Before App Store submission

- **A privacy policy URL**: set `LOCIS_PRIVACY_POLICY_URL` in
  `ios/Config/Locis.xcconfig` once the page is live.
- **Screenshots** taken on live data.

## Renaming the app

The name shown to users comes from one setting: `LOCIS_DISPLAY_NAME` in
`ios/Config/Locis.xcconfig`.

## Important

Parking information is provided as guidance. Always check local signs, road markings
and temporary restrictions before parking. Published data can be incomplete, late or
wrong, and many authorities have not published their orders yet. Where the app has
no data it shows nothing or grey, which never means parking is unrestricted.

## Licence

The code is released under the [MIT License](LICENSE).

That licence covers the code only. The Locis name and logo (`Logo/`, the app icon and
the in-app logo) are not covered by it and remain the property of Curated Design
Limited.

To regenerate the app icon after changing `Logo/logo.png`, run
`swift scripts/make-app-icon.swift` from the repository root.

The MIT licence also does not cover the data: parking data from D-TRO, bank holiday dates from
GOV.UK, and the Department for Transport example files in
`pipeline/tests/fixtures/` are Crown copyright and are used under the
[Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).
