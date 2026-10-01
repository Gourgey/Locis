# Original project brief

This is the brief the project was started from, unedited. Decisions that changed it are recorded in `docs/DECISIONS.md`.

```text
You are an expert iOS, backend, geospatial-data and transport-data engineer. I want you to build a production-quality iPhone parking application from this repository.

Do not merely write a plan. Inspect the repository, research the current official APIs/documentation where necessary, create the architecture, implement the code, run tests, fix errors and leave the project in a working state.

Where something cannot be completed because credentials or external access are missing, build the rest of the system properly, provide a mock/demo implementation so the app works, and document exactly what I need to supply later.

============================================================
1. PRODUCT
============================================================

Build a free iOS parking application for the UK, initially focused on London.

The fundamental use case is:

1. User searches for an address or place.
2. Alternatively, they navigate around the map manually.
3. They select the date/time they intend to arrive.
4. They select the date/time they intend to leave.
5. Parking restrictions around the visible area are displayed as coloured lines along the relevant kerbs/road sections.
6. The colours reflect whether the user can legally park for the ENTIRE selected stay.
7. Tapping a coloured parking segment opens detailed information explaining:
   - what type of parking/restriction it is;
   - whether the selected stay is permitted;
   - controlled hours;
   - free/paid status;
   - price where reliable tariff data is available;
   - maximum stay;
   - no-return period;
   - permit requirements;
   - vehicle restrictions;
   - disabled/Blue Badge restrictions;
   - loading restrictions where relevant;
   - temporary restrictions/suspensions where available;
   - source authority;
   - source/update date;
   - confidence/data-quality status.

The app is NOT intended to tell the user whether a physical parking space is currently unoccupied.

It answers:

“Am I legally allowed to park on this section of kerb for my selected time period?”

This distinction must be clear throughout the UI.

Working product name can simply be “Parking” for now. Keep naming easy to replace globally later.

============================================================
2. CORE PRODUCT PRINCIPLES
============================================================

The app should be:

- simple;
- map-first;
- fast;
- trustworthy;
- conservative when data is uncertain;
- free to use;
- without advertising;
- without subscriptions;
- without user accounts for V1;
- without tracking.

Do not copy AppyParking/AppyWay branding, artwork or interface.

The concept of coloured kerb overlays is generic and useful, but create our own visual system and interaction design.

Do not scrape AppyWay or any other proprietary parking service.

Use open/public data with appropriate licensing.

============================================================
3. PRIMARY DATA SOURCE: UK D-TRO
============================================================

Use the UK Department for Transport Digital Traffic Regulation Orders (D-TRO) service as the primary regulation source.

Before implementation, inspect the CURRENT official documentation rather than relying blindly on this prompt because the API/data model is actively evolving.

As of this project brief:

- D-TRO consumer access is free following registration.
- D-TRO data is licensed under Open Government Licence v3.0.
- Current D-TRO Data Model documentation is v4.0.0.
- v4.0.0 substantially changed condition/conditionSet nesting.
- D-TRO spatial geometry uses WKT.
- Spatial CRS is OSGB36 / British National Grid, EPSG:27700.
- Kerb restrictions may be represented using LINESTRING or MULTILINESTRING geometry.
- D-TRO can also use POINT, POLYGON and related geometries.
- linearGeometry can specify lateralPosition such as onKerb.
- the service provides an endpoint for obtaining all published D-TROs.
- the API provides an event-history mechanism for detecting create/update/delete events.
- D-TRO includes regulation types relevant to parking such as:
  kerbsideParkingPlace
  kerbsidePaymentParkingPlace
  kerbsidePermitParkingPlace
  kerbsideLimitedWaiting
  kerbsideNoWaiting
  kerbsideNoStopping
  kerbsideNoLoading
  kerbsideLoadingBay
  kerbsideLoadingPlace
  kerbsideDisabledBadgeHoldersOnly
  kerbsideMotorcycleParkingPlace
  kerbsideControlledParkingZone
  kerbsideRestrictedParkingZone
  kerbsideSingleRedLines
  kerbsideDoubleRedLines
  miscBaySuspension
  miscSuspensionOfParkingRestriction
  miscTemporaryParkingBay
  miscTemporaryParkingRestriction
  and other applicable regulation types.

The model can describe:
- what regulation applies;
- where it applies;
- when it applies;
- conditions/exclusions;
- vehicle characteristics;
- permits;
- maximum stay/no-return rules;
- potentially tariff/rate information.

Do not assume tariff data will always be complete. The official rate model has historically been described as experimental. Treat missing or ambiguous tariff information conservatively.

Never interpret absence of D-TRO data as unrestricted/free parking.

“No data” must be represented as UNKNOWN.

============================================================
4. LICENSING / ATTRIBUTION
============================================================

Add an About / Data Sources section to the app.

Include the required Open Government Licence attribution:

“Contains public sector information licensed under the Open Government Licence v3.0.”

Provide appropriate links/placeholders for:
- Department for Transport D-TRO;
- Open Government Licence;
- relevant data/source information.

Do not use copyrighted assets or proprietary datasets without permission.

============================================================
5. IOS TECHNOLOGY
============================================================

Build the iOS app using:

- Swift
- SwiftUI
- MapKit
- CoreLocation
- Swift Concurrency
- Apple's modern Observation/data-flow APIs where appropriate

Use the latest stable Xcode/Swift SDK available in the development environment.

Prefer Apple frameworks over third-party dependencies.

Avoid unnecessary third-party iOS packages.

Use a sensible modular architecture rather than putting everything into giant View files.

Suggested modules/layers:

App
Features
  Map
  Search
  ParkingDetails
  TimeSelection
  Settings
Services
  API
  Location
  Search
Models
DesignSystem
Utilities

Use protocols where they make testing and mock implementations practical.

============================================================
6. MAP EXPERIENCE
============================================================

The main screen should primarily be an Apple Map.

Include:

- search bar near the top;
- current-location button;
- map controls;
- selected arrival/departure control;
- optional parking filter control;
- parking overlays;
- compact legend.

Address/place searching should use Apple MapKit:
- MKLocalSearchCompleter where useful;
- MKLocalSearch for resolved search results.

Selecting an address should:
1. move the map to the result;
2. place a destination marker;
3. zoom to a sensible neighbourhood-level region;
4. load nearby parking data.

Allow users to browse/pan/zoom manually.

When the visible region changes substantially, request parking data for the new bounding box.

Debounce these requests so map movement does not spam the backend.

Do not reload data for tiny map movements if already cached.

============================================================
7. TIME SELECTION
============================================================

The selected parking period is fundamental to the application.

Provide a clean control such as:

Arrive
Today 14:00

Leave
Today 17:00

Default intelligently to something like:
- arrival: now rounded sensibly;
- departure: arrival + 2 hours.

Allow future dates and overnight stays.

Reject invalid ranges where departure <= arrival.

Changing the selected period should immediately recalculate/re-render the parking statuses without forcing the user to search again.

============================================================
8. MAP COLOUR SYSTEM
============================================================

Create our own clear map language.

Initial proposal:

GREEN:
Legal for the entire selected stay and no payment is required.

TEAL / BLUE-GREEN:
Legal for the entire selected stay, but payment is required.

AMBER:
Potentially legal, but conditions apply that the app cannot automatically confirm, such as:
- permit required;
- vehicle-specific eligibility;
- other conditional access.

RED:
Not legal to park for the complete selected period.

PURPLE or BLUE:
Special-purpose parking such as:
- disabled bay;
- motorcycle bay;
- loading-only space;
where it should be visually distinct from normal parking.

GREY:
Unknown / insufficient data / unsupported rule / ambiguous source.

The precise palette should be accessible and easy to distinguish.

Do not rely on colour alone. Details should always state the status textually.

Map lines should be clearly visible without obscuring Apple Maps.

Use MapPolyline/MKPolyline or the most appropriate current MapKit overlay APIs.

Where appropriate, make overlays tappable/selectable.

============================================================
9. CRITICAL DATA-SAFETY RULE
============================================================

NEVER turn incomplete information into “available parking”.

Examples:

No record returned:
UNKNOWN, not green.

Unsupported D-TRO condition:
UNKNOWN or CONDITIONAL, not green.

Ambiguous overlapping rules:
UNKNOWN unless the rules engine can resolve the conflict reliably.

Missing tariff:
May say “Paid parking — price unavailable”, but do not invent a price.

Uncertain geometry:
Do not draw a precise kerb line if the source only defines a broad zone.

The product should prefer:
“I cannot reliably determine this.”

over:
“You can park here.”

when confidence is insufficient.

============================================================
10. PARKING DETAILS SHEET
============================================================

Tapping a parking line should open a bottom sheet.

Example structure:

Portland Place

AVAILABLE FOR YOUR STAY

Selected:
14:00–17:00
Saturday 3 October

Paid parking
£X.XX/hour
Estimated total £XX.XX

Restrictions
Mon–Fri 08:30–18:30
Sat 08:30–13:30
Maximum stay: 4 hours
No return: 1 hour

Other conditions
Standard cars permitted
Permit holders: [information if relevant]

Data
Source: Westminster City Council / D-TRO
Updated: [date]
Confidence: High

[Directions]

If price cannot reliably be calculated:

Paid parking
Tariff unavailable — check local signage/payment provider.

Do not fabricate data.

============================================================
11. VEHICLE PROFILE
============================================================

V1 should support at least a lightweight parking eligibility profile.

Default:
- standard private car;
- no special permit;
- no Blue Badge.

Settings can contain:

Vehicle type:
- Car
- Motorcycle
- Van / light commercial vehicle
- Other

Blue Badge:
- Yes / No

Do not attempt to automatically claim eligibility for resident/business permits unless sufficient permit information is known.

If a bay requires a permit and we cannot establish that the user has the correct permit:
status = conditional/amber.

Design the model so permit support can become more sophisticated later.

============================================================
12. RULES ENGINE
============================================================

This is one of the most important pieces of the project.

Build a proper tested parking-rule evaluation engine.

Do NOT simply map regulationType -> colour.

It must evaluate whether a restriction allows the COMPLETE requested parking interval.

Inputs should conceptually include:

- normalized parking restriction/provision;
- requested arrival Date;
- requested departure Date;
- vehicle profile;
- permit/eligibility information;
- relevant timezone;
- temporary/suspension rules;
- overlapping restrictions.

Output should include something like:

ParkingEvaluation {
    status
    confidence
    reasons
    paymentRequired
    estimatedCost
    maxStay
    noReturn
    applicableRules
    unresolvedConditions
}

Use Europe/London for UK regulation calculations unless the underlying specification dictates otherwise.

Correctly handle:
- weekdays/weekends;
- multiple daily periods;
- recurrence;
- date ranges;
- overnight parking;
- intervals spanning midnight;
- exceptions/exclusions;
- maximum stay;
- no-return;
- vehicle conditions;
- Blue Badge conditions where encoded;
- permit restrictions;
- boolean conditionSets;
- nested AND/OR logic from current D-TRO schema;
- negated conditions;
- temporary restrictions;
- suspension rules;
- restrictions that become active or inactive during the requested parking stay.

Example:

Restriction:
Paid parking Saturday 08:30–13:30.

Requested stay:
Saturday 12:00–15:00.

The rules engine must split/evaluate the interval as necessary rather than only checking the arrival time.

If parking is legal throughout but only chargeable for part of the period, represent that correctly.

Do not implement a simplistic “check start time only” algorithm.

============================================================
13. OVERLAPPING RULES
============================================================

D-TRO provisions may overlap spatially and temporally.

Build a resolver that can deal with multiple applicable regulations.

Principles:

- active suspensions should override ordinary parking permissions;
- an explicit no-stopping/no-waiting rule should not be hidden by a parking-place rule;
- specialised bay restrictions must be considered;
- specific kerb/bay rules should generally be treated as more specific than broad contextual zones;
- temporary rules may supersede ordinary permanent rules;
- zone-level geometry must not automatically be interpreted as precise bay geometry.

However:

Do not invent UK traffic-law precedence rules.

If a conflict cannot be reliably resolved based on the source information, classify it as UNKNOWN/CONDITIONAL and expose the reason internally/in diagnostics.

Keep rule-resolution logic isolated and extensively tested so it can be improved later.

============================================================
14. BACKEND
============================================================

Do not place D-TRO API credentials inside the iPhone application.

Build a backend service.

Preferred stack:

Python
FastAPI
PostgreSQL
PostGIS
SQLAlchemy / GeoAlchemy where appropriate
Pydantic
Shapely
pyproj
httpx
pytest

Use Docker Compose for local development.

Suggested repository structure:

/
  ios/
  backend/
  docs/
  scripts/
  docker-compose.yml
  README.md

The backend should:

1. obtain D-TRO data;
2. preserve source/raw information;
3. parse the D-TRO schema;
4. extract relevant parking provisions;
5. normalize parking rules;
6. convert spatial geometry;
7. store/query it efficiently;
8. evaluate parking rules;
9. return lightweight map data to the iPhone.

============================================================
15. GEOSPATIAL PIPELINE
============================================================

D-TRO geometry currently uses WKT with EPSG:27700.

Parse the WKT safely.

Store original/source geometry where useful.

Convert data to WGS84 / EPSG:4326 for interchange with Apple MapKit.

PostGIS can retain geometry in an appropriate projection internally as long as transformations and indexes are correct.

Support:
- LINESTRING;
- MULTILINESTRING;
- POLYGON;
- MULTIPOLYGON;
- POINT where relevant.

For kerb-line overlays, prioritize actual linear kerb geometry.

Do not manufacture exact kerb geometry from a broad polygon.

If a regulation is represented only as a zone:
- store the zone;
- use it as contextual information;
- optionally show an unobtrusive translucent zone overlay;
- do not pretend the zone boundary is a parking bay.

Use spatial indexes.

The phone should only receive parking features relevant to the current viewport/bounding box.

============================================================
16. NORMALIZED DATABASE
============================================================

Design a sensible schema.

At minimum consider tables/models resembling:

dtro_records
- id
- source_dtro_id
- schema_version
- authority
- created_at_source
- modified_at_source
- raw_payload
- imported_at
- active/deleted state

provisions
- id
- dtro_record_id
- source_reference
- regulation_type
- description
- effective dates
- timezone
- normalized fields
- raw provision data

regulated_places
- id
- provision_id
- description
- geometry
- geometry_type
- lateral_position
- direction
- source CRS
- normalized WGS84 geometry

conditions
or a suitable normalized/JSON representation that retains D-TRO boolean semantics.

tariffs
where appropriate.

Do not over-normalize if doing so would destroy or complicate the nested semantic structure.

It is acceptable to preserve complex conditions in structured JSON alongside useful indexed normalized fields.

Preserve enough raw source material that parsing bugs can later be diagnosed without downloading everything again.

============================================================
17. DATA INGESTION
============================================================

Implement two workflows.

A. INITIAL IMPORT

Use the official mechanism for obtaining all current published D-TROs.

Download/import them.

Filter/process parking-relevant records.

Store progress/checkpoints.

Make the importer resumable.

Do not load the entire national dataset into RAM if it can reasonably be streamed/batched.

B. INCREMENTAL UPDATES

Use the official D-TRO event/search mechanisms to detect:
- creates;
- updates;
- deletes.

Persist the timestamp/cursor/checkpoint of the latest successful sync.

Update only affected records.

Make sync idempotent.

If the service changes, isolate D-TRO API interactions behind an adapter so they can be updated without rewriting the application.

============================================================
18. D-TRO VERSIONING
============================================================

Do not tightly couple the entire application to one schema version.

Create a parsing/adaptor layer.

For example conceptually:

DTROParser
  DTROv4Parser
  future parser implementations

Current implementation should properly support current v4.0.0 data.

If an unsupported schema version appears:
- preserve the record;
- log it;
- mark parsing status appropriately;
- do not silently misinterpret it.

============================================================
19. BACKEND API FOR IOS
============================================================

Create a clean versioned API.

For example:

GET /health

GET /v1/parking/segments
Parameters:
- north
- south
- east
- west
- start
- end
- vehicleType
- blueBadge
- optional filters

Response can use GeoJSON FeatureCollection or another efficient documented format.

Every map feature should contain enough summary information to draw it:

- stable segment ID
- geometry
- evaluated status
- confidence
- parking category
- paid/free/conditional indicator
- concise reason

GET /v1/parking/segments/{id}
returns full detail.

GET /v1/data/status
returns useful information such as:
- last successful D-TRO sync;
- data/schema version;
- health/status.

Do not expose raw credentials.

Validate parameters.

Apply sensible response limits.

Consider caching.

============================================================
20. PERFORMANCE
============================================================

The app should feel immediate.

Backend:
- PostGIS spatial indexes;
- bbox queries;
- indexes on relevant regulation fields;
- avoid parsing raw D-TRO JSON on every user request.

iOS:
- debounce viewport calls;
- cancel stale network requests;
- cache recently loaded geographic areas where sensible;
- avoid creating thousands of expensive SwiftUI subviews unnecessarily;
- aggregate/simplify rendering at very wide zoom levels if required.

Do not download all London parking data to the phone on every launch.

============================================================
21. FILTERS
============================================================

Provide a simple initial filter control:

All
Free
Paid
Conditional

Do not allow a filter to imply that unknown roads are free.

Potential later filters:
- maximum stay;
- Blue Badge;
- motorcycle;
- permit;
- EV.

Keep V1 simple.

============================================================
22. DIRECTIONS
============================================================

From a selected parking segment, provide:

“Directions”

This can hand the location off to Apple Maps using the standard Apple MapKit APIs.

No custom turn-by-turn navigation is required.

============================================================
23. LOCATION PRIVACY
============================================================

Only request When In Use location permission.

Do not request Always permission.

Do not request location until it is needed or the user requests current location.

Do not track historical user locations.

Do not create an account.

Do not persist map searches or user location on the server unless technically necessary.

Avoid logging precise coordinates in production application logs.

Include the appropriate Apple privacy manifest and Info.plist usage description.

============================================================
24. DISCLAIMER / SAFETY UX
============================================================

Parking regulation data can be incomplete, delayed or incorrect.

Include appropriate wording such as:

“Parking information is provided as guidance. Always check local signs, road markings and temporary restrictions before parking.”

Do not make the interface alarmist, but do not represent the application as legally authoritative.

Show source and freshness where practical.

============================================================
25. DATA CONFIDENCE
============================================================

Implement a first-class confidence system.

For example:

HIGH
Source rule parsed successfully.
Geometry is sufficiently precise.
No unsupported relevant conditions.
No detected conflicts.

MEDIUM
Data usable but some secondary detail is incomplete.

LOW
Important information missing or ambiguous.

UNKNOWN
Cannot make a reliable decision.

Confidence should affect the UI.

The app must never transform LOW/UNKNOWN into a confident green result.

============================================================
26. DEMO / DEVELOPMENT MODE
============================================================

I may not initially provide D-TRO production credentials.

The entire application must still be buildable and testable.

Create a demo mode containing SYNTHETIC sample data representing a fictional London-style area or clearly labelled test fixtures.

Include examples for:
- free unrestricted-for-selected-time parking;
- paid parking;
- permit parking;
- no waiting;
- maximum stay;
- no return;
- disabled bay;
- loading bay;
- parking suspension;
- rule ending part-way through a requested stay;
- overlapping rules;
- unknown/unsupported condition.

Do not present synthetic data as genuine parking information.

Switching between demo and live backend configuration should be straightforward.

============================================================
27. TESTING
============================================================

Testing is extremely important because incorrect parking logic could lead to fines.

BACKEND UNIT TESTS

Create comprehensive tests for the rules engine.

At minimum test:

- fully allowed interval;
- fully prohibited interval;
- restriction starts during stay;
- restriction ends during stay;
- multiple time periods;
- weekday/weekend;
- crossing midnight;
- crossing into another weekday;
- max stay exceeded;
- max stay exactly met;
- no-return information;
- paid period;
- partly paid / partly unrestricted period;
- permit-only;
- Blue Badge condition;
- wrong vehicle type;
- nested AND conditionSet;
- nested OR conditionSet;
- negated condition;
- temporary restriction;
- suspension overriding ordinary parking;
- overlapping permission/prohibition;
- missing information;
- unsupported condition;
- invalid geometry/data;
- daylight saving transition where relevant.

INGESTION TESTS

Use fixtures for D-TRO v4 payloads.

Test:
- WKT parsing;
- EPSG:27700 -> EPSG:4326 conversion;
- LINESTRING;
- MULTILINESTRING;
- POLYGON;
- event updates;
- deletion;
- idempotent reimport;
- unsupported schema version.

IOS TESTS

Test key view models/services.

At minimum:
- time selection validation;
- API response decoding;
- parking status -> visual style mapping;
- search results;
- error states.

The project should build cleanly.

============================================================
28. ERROR STATES
============================================================

Design proper user-facing states.

Examples:

No D-TRO data:
“No reliable parking data is available here yet.”

Backend unavailable:
“Parking data is temporarily unavailable.”

Unsupported rule:
“Parking rules are available for this location, but this restriction cannot yet be interpreted reliably. Check local signs.”

No internet:
show cached information only if its age/source is made clear.

Never display an empty map in a way that implies unrestricted parking.

============================================================
29. VISUAL DESIGN
============================================================

The design should be polished, restrained and native to iOS.

Think:
- Apple Maps-level clarity;
- simple translucent materials where appropriate;
- rounded sheets/cards;
- strong hierarchy;
- minimal clutter;
- compact map controls.

Avoid:
- excessive gradients;
- gamification;
- giant cards covering the map;
- copying AppyParking;
- visual gimmicks.

The parking-colour system is the dominant information hierarchy.

Support:
- light mode;
- dark mode;
- Dynamic Type where practical;
- VoiceOver;
- sufficient colour contrast.

============================================================
30. APP STORE READINESS
============================================================

Prepare the project so it can eventually be submitted to the App Store.

Include:

- appropriate app capabilities;
- location usage description;
- privacy manifest as required;
- no private APIs;
- no embedded secrets;
- About/Data Sources screen;
- licence attribution;
- parking-information disclaimer;
- placeholder privacy-policy link/configuration if necessary.

There are no:
- subscriptions;
- purchases;
- ads;
- analytics SDKs;
- account requirements
for V1.

============================================================
31. DEVELOPMENT / DEPLOYMENT EXPERIENCE
============================================================

I develop on a Mac.

Make local setup straightforward.

Ideally:

docker compose up -d

starts:
- PostgreSQL/PostGIS;
- backend dependencies/services as appropriate.

Document:
- prerequisites;
- environment variables;
- database migrations;
- initial import;
- incremental sync;
- demo mode;
- backend startup;
- iOS configuration;
- running in Simulator;
- running on a physical device.

Provide .env.example.

Never commit .env or credentials.

Use database migrations rather than manually created production schemas.

============================================================
32. DOCUMENTATION
============================================================

Create a useful README.

Also create:

docs/ARCHITECTURE.md
docs/DTRO.md
docs/RULES_ENGINE.md
docs/DEPLOYMENT.md

DTRO.md should document:
- source;
- licensing;
- current supported schema;
- ingestion process;
- geometry conversion;
- known limitations.

RULES_ENGINE.md should explain:
- evaluation model;
- interval logic;
- confidence;
- overlapping rule strategy;
- unsupported conditions;
- how to add future regulation types.

============================================================
33. IMPORTANT NON-GOALS FOR V1
============================================================

Do NOT spend time building:

- parking payments;
- live occupancy sensors;
- social/community reports;
- accounts;
- subscriptions;
- advertising;
- CarPlay;
- Android;
- custom navigation;
- nationwide local-authority scraping;
- AppyWay integrations;
- machine-learning parking predictions.

Architect cleanly enough that features can be added later, but do not overengineer them now.

============================================================
34. DEVELOPMENT ORDER
============================================================

Work in this order:

PHASE 1
Inspect repository/environment and current official D-TRO documentation.

PHASE 2
Set up backend, database and core models.

PHASE 3
Implement synthetic fixtures and parking rules engine FIRST.

Get comprehensive rule tests passing.

PHASE 4
Implement D-TRO v4 parser and geospatial transformation.

PHASE 5
Implement data ingestion/synchronisation.

If live credentials are unavailable, retain a functioning mock/live adapter boundary and continue.

PHASE 6
Build backend parking-query API.

PHASE 7
Build SwiftUI app and map experience.

PHASE 8
Connect iOS to backend.

PHASE 9
Build details, search, time selection, filters and settings.

PHASE 10
Test end-to-end, profile performance, fix errors and improve UX.

PHASE 11
Finish documentation and App Store-related configuration.

Do not stop after each phase asking me whether to continue unless a decision genuinely cannot be made safely.

Make sensible engineering decisions autonomously.

============================================================
35. DEFINITION OF DONE
============================================================

The first meaningful release is complete when I can:

1. Open the iPhone app.
2. See an Apple Map.
3. Search for an address.
4. Move around the map manually.
5. Select arrival and departure times.
6. See coloured kerb/parking segments.
7. Have those colours update based on the selected period.
8. Tap a segment.
9. See a clear explanation of its parking rules.
10. Distinguish:
    - free;
    - paid;
    - permit/conditional;
    - prohibited;
    - specialist;
    - unknown.
11. See maximum stay/no-return information where available.
12. See cost where reliable source tariff data permits calculation.
13. See source/confidence information.
14. Open directions in Apple Maps.
15. Run the same app against demo data when live D-TRO access is unavailable.
16. Run backend automated tests successfully.
17. Build the iOS target successfully.
18. Follow README instructions from a fresh Mac development setup.

============================================================
36. FIRST ACTION
============================================================

Start now.

First:

1. inspect the repository and development environment;
2. read the current official D-TRO API, Data Model and licensing documentation;
3. confirm current D-TRO schema/API assumptions in docs/DTRO.md;
4. inspect the latest relevant Apple MapKit APIs available in the installed SDK;
5. create the project architecture;
6. begin implementing it.

Do not only report what you intend to do.

Create and modify the actual project files.

If D-TRO credentials are missing, do not treat that as a blocker:
build the complete demo path, credential configuration and D-TRO adapter so live credentials can be inserted later.

Prioritise correctness of the parking rules over feature count or visual polish.
```
