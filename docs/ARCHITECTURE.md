# Architecture

Locis has two halves joined by static files.

```
            ┌──────────────────────── pipeline (Python) ────────────────────────┐
D-TRO API ─►│ dtro_client ─► store (SQLite) ─► parsers ─► relate ─► tiles       │─► manifest.json
            │   adapter       raw payloads      v4 / v3.5   overlaps   + manifest│   tiles/z/x/y-hash.json
            └───────────────────────────────────────────────────────────────────┘
                                                                  │ static hosting
            ┌──────────────────────── iPhone app (Swift) ───────────────────────┐
            │ RemoteDataProvider ─► ParkingMapModel ─► ParkingRulesEngine ─► UI  │
            │   cache by hash        viewport, stay      whole-stay evaluation   │
            └───────────────────────────────────────────────────────────────────┘
```

The reasons for this shape are in [DECISIONS.md](DECISIONS.md).

## Pipeline (`pipeline/src/locis_pipeline`)

| Module | Responsibility |
|---|---|
| `dtro_client.py` | Everything that knows the D-TRO API: OAuth token, bulk extract, events, single records. `DTROSource` is the interface; `LiveDTROSource`, `FixtureDTROSource` and `DemoDTROSource` implement it |
| `store.py` | SQLite working store: raw payloads verbatim, parse status, features, sync checkpoints, versioned migrations |
| `ingest.py` | `initial_import` (batched, resumable, idempotent) and `incremental_sync` (events since the checkpoint) |
| `parsers/` | `base.py` shared record parsing; `v4.py` and `v35.py` schema adapters; `common.py` condition, time and tariff normalisation |
| `regulations.py` | Which D-TRO regulation types are parking-relevant, and their role and category |
| `geo.py` | EWKT parsing and validation, EPSG:27700 to WGS84 (OSTN15), tile maths |
| `relate.py` | Which provisions overlap on the same kerb, and which zones a kerb lies in |
| `tiles.py` | Writes the manifest and content-hashed tiles |
| `holidays.py` | England and Wales bank holidays (GOV.UK, with a computed fallback) |
| `demo.py` | The synthetic demo dataset, as valid D-TRO records |
| `cli.py` | The `locis` command |

The pipeline never evaluates a stay. It normalises rules and publishes them with
their boolean structure intact.

## LocisKit (`ios/LocisKit`)

A Swift package with no UI and no third-party dependencies, so its tests run with
`swift test` on a Mac in a couple of seconds.

| Folder | Responsibility |
|---|---|
| `Models/` | `Feature`, the condition tree, `Manifest`, `VehicleProfile`, `ParkingEvaluation` |
| `Engine/` | `TimeEvaluator`, `ConditionEvaluator`, `ProvisionEvaluator`, `ParkingRulesEngine`, `CostCalculator`, `Describe` |
| `Data/` | Tile maths, `ParkingDataProviding`, `DemoDataProvider`, `RemoteDataProvider` (with on-device cache) |
| `Presentation/` | `StaySelection`, `ParkingMapModel` |
| `Resources/demo/` | The bundled demo dataset |

## App (`ios/Locis`)

| Folder | Contents |
|---|---|
| `App/` | Entry point, `AppModel`, `AppConfiguration`, `SettingsStore` |
| `Features/Map` | `MapScreen`, `ParkingMap` (overlays and hit testing), legend |
| `Features/Search` | `SearchViewModel`, `SearchField` |
| `Features/TimeSelection` | `StayControl`, `StayEditorSheet` |
| `Features/ParkingDetails` | `ParkingDetailSheet` |
| `Features/Settings` | `SettingsScreen`, `AboutScreen` |
| `Services/` | `PlaceSearching` + MapKit implementation, `LocationService`, `Directions` |
| `DesignSystem/` | `ParkingStyle`: status to colour, weight, dash, symbol |

Services sit behind protocols (`ParkingDataProviding`, `PlaceSearching`,
`HTTPFetching`) so tests substitute fakes.

## Request flow in the app

1. The map region settles. `ParkingMapModel.viewportChanged` debounces (350 ms) and
   cancels any stale load.
2. If the map is zoomed out past about 4 km tall, nothing is loaded and the app says
   "Zoom in".
3. The manifest is fetched (reused for 15 minutes; a cached copy is used offline and
   labelled with its date).
4. The tiles covering the viewport plus a 25% margin are worked out. Tiles already
   loaded are not requested again, so small pans cost nothing.
5. Each tile is read from memory, then the device cache, then the network. Tile
   names contain a content hash, so a cached tile is valid for as long as the
   manifest lists that hash.
6. Every drawable feature is evaluated off the main thread for the selected stay and
   profile. Changing the stay or the profile repeats only this step.

## Performance

- Tiles are about 0.76 km across at zoom 15; a neighbourhood view needs 6 to 12.
- A tile carries everything its features are evaluated against, so no neighbouring
  tile is ever needed to evaluate what is on screen.
- 1,500 overlapping features evaluate for an overnight stay in about 0.3 s in a
  release build on an Intel Mac (`PerformanceTests`).
- At most 120 tiles are held; beyond that the model drops what it has.

## Privacy

- The app has no account, analytics or tracking, and sends nothing about the user.
- Location permission is "when in use" only, requested when the user taps the
  location button. The position is used by MapKit on the device.
- Searches go to Apple's MapKit service and are not stored.
- Tile downloads reveal to the static host which ~0.76 km tiles were requested, as
  any map does. No coordinates, times or identifiers are sent.
