# Published data format (version 1)

The pipeline writes, and the app reads:

```
manifest.json
tiles/<zoom>/<x>/<y>-<hash>.json
```

Tiles use the standard Web Mercator XYZ scheme at one zoom level (15 by default).
`<hash>` is the first 12 hex digits of the SHA-256 of the tile's bytes, so a tile
URL never changes its content and can be cached forever.

## manifest.json

| Field | Meaning |
|---|---|
| `formatVersion` | Version of this format. The app refuses any other |
| `minEngineVersion` | Lowest app rules-engine version allowed to interpret the data |
| `dataset` | `live` or `demo` |
| `synthetic`, `notice` | True for made-up data, with the text to show |
| `generatedAt`, `lastSync`, `lastFullImport` | UTC timestamps |
| `tileZoom` | Zoom level of the tiles |
| `transformation` | `OSTN15` or the Helmert fallback used for coordinates |
| `bounds`, `region` | `[west, south, east, north]` |
| `counts` | Records, features, tiles, by parse status and by schema version |
| `authorities` | Authorities with published features |
| `holidays` | Bank holidays: `from`, `to`, `dates`, `goodFridays`, `source` |
| `source` | Name, URL, licence and attribution text |
| `tiles` | `"x/y"` to tile hash |

## Tile

`{"v": 1, "z": 15, "x": 16358, "y": 10906, "features": [Feature, ...], "context": [Feature, ...]}`

`features` holds every feature whose geometry touches the tile: these are drawn.
`context` holds features from neighbouring tiles that those are evaluated against
(`related`, `zones`): the app uses them for evaluation but does not draw them from
this tile. An app that ignored `context` would find related rules missing and show
those kerbs as unknown, which is the safe failure.

Orders whose every time condition has already ended are left out of the tiles
(`counts.expiredOmitted` in the manifest says how many).

## Feature

One regulated place of one D-TRO provision.

| Field | Meaning |
|---|---|
| `id` | Stable 16-hex id from record id, provision reference and place index |
| `dtro`, `prov` | D-TRO record id and provision reference |
| `reg` | D-TRO `regulationType`, or `offList` |
| `role` | `permission`, `prohibition`, `baySuspension`, `restrictionSuspension`, `zone`, `info`, `unsupported` |
| `cat` | Category: `standard`, `paid`, `permit`, `limitedWaiting`, `disabled`, `motorcycle`, `loading`, `taxi`, `cycle`, `noWaiting`, `noStopping`, `noLoading`, `redRoute`, `clearway`, `zigzag`, `busStop`, `crossing`, `footway`, `suspension`, `controlledParkingZone`, `restrictedParkingZone`, `permitParkingArea`, `other` |
| `name`, `desc`, `tro` | Place description, provision description, order name |
| `auth`, `authCode` | Authority name and SWA-like code |
| `orp`, `temporary` | Order reporting point; true for temporary orders |
| `lifecycle` | Absent when in force; `intended` or `revocation` |
| `from`, `until` | Coming-into-force and cessation dates (`yyyy-MM-dd`, London) |
| `overrides` | Provision references this provision replaces while it applies |
| `activity` | Recorded on-street start and stop events |
| `cond` | Condition tree (below) |
| `geom` | `{"type": "line"|"polygon"|"point", "coords": ...}` in WGS84, longitude first |
| `geomQuality` | `kerb`, `centreline`, `zoneLine`, `area`, `point` |
| `issues` | Data-quality flags: `dynamic`, `placeholder`, `timeZone`, `unsupportedCondition`, `legacyConditionNesting`, `exemptionList`, `oversized` |
| `related`, `partial`, `zones` | Ids of overlapping provisions, the subset that overlap only partly, and containing zones |
| `updated`, `published`, `schema` | Source timestamps and schema version |

Geometry: `line` is a list of parts, each a list of `[lon, lat]`; `polygon` is a
list of polygons, each a list of rings (outer first); `point` is a list of positions.

## Condition tree

D-TRO's rule is preserved exactly: a tree is true for the road users and times to
which the regulation's effect applies.

```
{"op": "and" | "or" | "xor", "items": [node, ...]}
{"not": node}
{"time": {"start", "end"?, "valid": [period], "except": [period], "maxStay"?, "noReturn"?}}
{"vehicle": {"type"?, "usage"?, "fuel"?: [...], "unsupported"?: [...]}}
{"permit": {"type", "scheme"?, ...}}
{"driver": "disabledWithPermit" | ...}
{"occupant": {"disabled"?: bool, "count"?: [...]}}
{"access": [...]}   {"road": "..."}   {"nonVehicular": "..."}
{"other": "free text"}
{"concessions": [node, ...]}
{"unsupported": "reason"}
```

`concessions` is a published list of exemptions (see "Exemption lists" in
[DTRO.md](DTRO.md)). It is always true: it does not narrow who a rule applies to,
and its contents are shown as information only.

Any node may also carry `rate` (a tariff charged while the node holds) or
`rateUnusable`.

A period: `from`/`to` (UTC instants), `times` (`[start, end)` seconds after local
midnight; an end before the start wraps past midnight), `days` (rules with `dow`
1 = Monday to 7 = Sunday, `months`, `dom`, `instance`), `special` (special days
with `intersect`), `maxStay`, `noReturn` (seconds), and `unsupported` (parts that
could not be interpreted).

All instants are UTC. Times of day and dates are Europe/London wall-clock.

## Changing the format

- Additive changes that old apps can safely ignore: no version change.
- Anything an old app would misread: raise `MIN_ENGINE_VERSION` in
  `pipeline/src/locis_pipeline/__init__.py` and `engineVersion` in
  `ParkingRulesEngine`. Older apps then show a notice and draw nothing.
- A change to the file structure: raise `TILE_FORMAT_VERSION` and
  `SupportedFormat.tileFormatVersion`.
