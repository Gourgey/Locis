# Locis

iPhone app showing whether you may legally park on a UK kerb for a whole chosen
stay. Data: DfT D-TRO. Read `docs/DECISIONS.md` first: there is **no server**; a
Python pipeline publishes static tiles and the rules engine runs on the phone.

## Non-negotiable rules

- Never turn missing, unsupported or ambiguous data into "available". No data means
  UNKNOWN, never free. When unsure, the answer is unknown or conditional.
- Do not invent UK traffic-law precedence. Unresolvable overlaps are unknown.
- Never invent a price. Unreadable tariff means "Tariff unavailable".
- No credentials in the app or the repository. D-TRO credentials live in `.env`
  (git-ignored) or GitHub secrets.
- No accounts, analytics, adverts, tracking or third-party iOS dependencies.
- D-TRO condition semantics: a tree is true for the users and times the regulation
  applies to; exemptions are negations. Do not infer polarity from regulation type.

## Layout

- `pipeline/` Python: `dtro_client.py` (only place that knows the API),
  `parsers/` (v4 and v3.5 adapters), `geo.py`, `relate.py`, `tiles.py`, `demo.py`.
- `ios/LocisKit/` Swift package: models, `Engine/` (rules), `Data/`, `Presentation/`.
- `ios/Locis/` SwiftUI app. `ios/Locis.xcodeproj` uses file-system-synchronised
  groups: new files under `ios/Locis` or `ios/LocisTests` are picked up automatically.

## Commands

- `scripts/setup.sh` create the Python environment
- `scripts/test-all.sh [--skip-app]` all tests
- `cd pipeline && .venv/bin/pytest` pipeline tests
- `cd ios/LocisKit && swift test` rules-engine tests (fast, no Simulator)
- `scripts/build-demo-data.sh` regenerate bundled demo data after changing `demo.py`
- `scripts/run-simulator.sh` build and run in the Simulator

## Conventions

- British English in UI text and docs.
- The tile format is a contract between Python and Swift (`docs/TILE_FORMAT.md`).
  Change both sides together, and follow "Updating the rules engine safely" in
  `docs/DEPLOYMENT.md` when old apps would misread new data.
- Every rules change needs a test; safety-relevant ones also need a demo scenario.
- This Mac is Intel: Homebrew has no bottles for it, so prefer pip and official
  release binaries over `brew install`.
