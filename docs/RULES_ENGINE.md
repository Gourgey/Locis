# Rules engine

The engine answers: may this vehicle legally stay parked on this kerb from arrival
to departure? It lives in `ios/LocisKit/Sources/LocisKit/Engine` and is tested by
`ios/LocisKit/Tests` (run `swift test`).

One rule shapes everything: **incomplete information is never turned into
"available".** The engine prefers "cannot be determined" to "you can park here".

## Inputs and output

```swift
ParkingRulesEngine(holidays:).evaluate(
    feature,              // the kerb feature
    context: [id: Feature], // loaded features, including everything in feature.related
    stay: Stay,           // arrival and departure
    profile: VehicleProfile, // vehicle type, Blue Badge
    dataIncomplete: Bool) -> ParkingEvaluation
```

`ParkingEvaluation` carries `status`, `confidence`, `reasons`, `confidenceNotes`,
`paymentRequired`, `chargeableSeconds`, `estimatedCost`, `costNote`, `limits`
(max stay, no return), `applicableRuleIDs`, `unresolvedConditions` and `segments`.

| Status | Meaning | Map |
|---|---|---|
| `allowedFree` | Legal for the whole stay, nothing to pay | Green |
| `allowedPaid` | Legal for the whole stay, payment for at least part | Teal |
| `conditional` | Depends on something the app cannot confirm | Amber |
| `specialist` | A bay reserved for users the profile is not | Purple |
| `prohibited` | Not legal for the whole stay | Red |
| `unknown` | Cannot be determined | Grey, dotted |

## Evaluation model

### 1. Cut the stay into segments

Every instant at which any rule on the kerb could change state is collected: time
windows opening and closing on each local day of the stay, validity start and end,
period bounds, coming-into-force dates, recorded start/stop events, and clock
changes. The stay is cut at those instants. Within a segment nothing changes, so
each segment is evaluated once, at its midpoint.

This is why a stay of Saturday 12:00 to 15:00 in a bay charged until 13:30 comes out
as "paid for 1 hr 30 min, then free": two segments, not a check of the arrival time.

All wall-clock work is in Europe/London (`LondonCalendar`). Day rules apply to the
day a time window starts, so "Monday 22:00 to 06:00" covers Tuesday morning. Around
a clock change, extra cut points an hour either side make sure a repeated or skipped
hour is handled.

### 2. Evaluate each provision in the segment

`ConditionEvaluator` evaluates the condition tree twice:

- for **anyone** ("is this in force for somebody at this time?"), where conditions
  about who the user is count as "some users";
- for the **profile**.

Answers are not just true and false:

| Value | Meaning |
|---|---|
| yes / no | Certain |
| eligibility(...) | Depends on a permit or similar the app cannot confirm |
| unsupported(...) | Depends on something the engine cannot interpret |

`and`, `or`, `xor` and `not` follow three-valued logic, so an uninterpretable
condition only matters when it could change the answer: "weekdays AND <unknown>" is
simply false on a Sunday.

`ProvisionEvaluator` turns that into an **effect**, by the provision's role:

| Role | Effects |
|---|---|
| prohibition | `prohibits`, `notAffected` (user is exempt), `needs`, `unknown` |
| permission | `permits(paid)`, `reserved` (in force for others), `needs`, `unknown`, `inactive` (outside hours) |
| baySuspension | `suspendsBays` |
| restrictionSuspension | `liftsRestrictions` (only when it certainly applies) |
| zone, info | `info` |
| unsupported | `unknown` |

Two kinds of "not applying" are kept apart:

- **inactive**: a current order outside its hours (a single yellow line at night);
- **absent**: not yet in force, ended, or outside its validity dates. An absent
  provision takes no part at all. An expired temporary order must not read as
  "restriction lifted, so parking is fine".

Some eligibility comes from the kind of bay, whatever the conditions say: disabled
bays need a Blue Badge, motorcycle bays a motorcycle, loading bays, taxi ranks and
cycle parking are never for parking a car, and a permit bay with no permit described
still needs a permit.

### 3. Resolve overlapping provisions

`ParkingRulesEngine.resolve` combines the kerb feature with everything in its
`related` list, in this order:

1. **Overrides.** A temporary provision, or a suspension of a restriction, removes
   the provisions it names in `overrides` for as long as it is active.
2. **Prohibitions.** Any provision that prohibits makes the segment prohibited. A
   parking place never hides a no-waiting or no-stopping rule.
3. **Suspensions.** An active bay suspension makes the segment prohibited when there
   is a bay here, including outside the bay's own hours.
4. **Unknowns.** If anything left is undeterminable, the segment is unknown.
5. **Parking places.**
   - None in force, but bays exist: outside controlled hours. Allowed free for
     ordinary bays; conditional for specialist bays ("check the sign").
   - None in force, only an inactive restriction: allowed free ("restriction not in
     force").
   - Nothing about waiting at all (for example only a loading restriction): unknown.
   - Specialist and ordinary bays both in force, or two kinds of specialist bay:
     unknown. The source does not say which wins.
   - Otherwise parking places are grants. Any that applies is enough (a shared-use
     permit/paid bay is allowed, paid); a free grant is preferred; stay limits are
     the tightest of the grants in force.
6. An eligibility question raised by a restriction (permit-holder exemption, planned
   order) turns an allowed result into conditional.

No precedence rule beyond these is assumed. What cannot be resolved is unknown, with
the reason shown in the details.

### 4. Combine the segments

The worst segment decides: prohibited, then unknown, specialist, conditional, paid,
free.

- **Maximum stay.** Time parked while a limit is in force must not exceed it. Time
  outside the controlled period does not count. Exactly the limit is allowed.
- **Stays through several limited periods** (one hour on Monday evening, one on
  Tuesday morning, vehicle never moved) are **conditional**: orders differ on this.
- **No return** is reported, not evaluated: the app does not know your history.
- **Payment.** Chargeable time is the sum of paid segments.

### 5. Cost

`CostCalculator` prices only structures with one reading:

- exactly one rate collection valid at the start, in GBP;
- one `incrementingRate` or `perUnit` line with an increment (rounded up to whole
  units); or bands of `flatRateTier` where exactly one band contains the stay; or
  one `flatRate` for a stay within a single day;
- minimum and maximum charges applied;
- a single, contiguous charged period under a single tariff.

Bands are used exactly as published: a band ending 01:59:59 does not include a stay
of exactly two hours. Anything else gives "Tariff unavailable". A price is never
estimated.

## Confidence

Each of these lowers confidence one step and is listed in the details:

- geometry is not a kerb line (centreline, area, point);
- part of the stay is allowed only because no restriction is in force;
- more than one parking rule is recorded on the kerb;
- another rule covers part of the section;
- the record uses the older, ambiguous condition nesting.

None: **high**. One or two: **medium** (drawn dashed when allowed). Three or more:
**low**, and a low-confidence result that would be allowed becomes **unknown**. An
unknown status always has unknown confidence.

Besides that, results are unknown whenever: a related rule is not loaded, a tile had
unreadable features, the rule is dynamic or a placeholder, a revocation is recorded
on the kerb, or the dataset needs a newer engine.

## Vehicle profile

`VehicleProfile` is vehicle type (car, motorcycle, van, other) and Blue Badge.
"Other" is never assumed to match a vehicle condition. Permits are never assumed.
To support permits later, add them to `VehicleProfile` and match them in
`ConditionEvaluator.permit`; nothing else needs to change.

## Adding a regulation type

1. Add it to `REGULATION_TYPES` in `pipeline/src/locis_pipeline/regulations.py` with
   a role and category. If an existing role and category fit, the engine needs no
   change.
2. For a new category, add it to `Category` in `Feature.swift`, to
   `Describe.category`, and to `isSpecialist` or `prohibitionNote` if relevant.
3. For a new role, add an `Effect` in `ProvisionEvaluator` and a step in `resolve`,
   and raise `engineVersion` and `MIN_ENGINE_VERSION` together so older apps do not
   misread the data.
4. Add a scenario to `demo.py`, run `scripts/build-demo-data.sh`, and add tests.

## Tests

`RulesEngineTests.swift` covers intervals, limits, payment, eligibility, nested
AND/OR/XOR, negation, overlaps, suspensions, temporary orders, unsupported data and
clock changes. `DemoDatasetTests.swift` evaluates the pipeline's synthetic dataset
end to end, and checks the safety property across every feature, ten stays and every
profile: an allowed result always has at least medium confidence, every segment
allowed, and a real rule in force behind it.
