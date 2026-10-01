"""Classification of D-TRO regulation types for parking purposes.

Each regulation type gets a *role* (how it takes part in the evaluation) and a
*category* (what kind of kerb space it is). The rules engine in the app works from
role and category, so a new D-TRO regulation type only needs a row here.

A regulation type that is not listed is NOT parking-relevant and is not published.
A parking-looking type we cannot interpret must be listed with role ``unsupported``
so the app shows it as unknown instead of silently dropping it.
"""

from __future__ import annotations

# Roles
PERMISSION = "permission"  # a place where waiting is permitted for some population
PROHIBITION = "prohibition"  # waiting or stopping is prohibited for some population
BAY_SUSPENSION = "baySuspension"  # suspends bays: they cannot be used while it applies
RESTRICTION_SUSPENSION = "restrictionSuspension"  # lifts a restriction while it applies
ZONE = "zone"  # contextual area, never drawn as a kerb line
INFO = "info"  # relevant context that does not decide whether waiting is legal
UNSUPPORTED = "unsupported"

# Categories
STANDARD = "standard"
PAID = "paid"
PERMIT = "permit"
LIMITED_WAITING = "limitedWaiting"
DISABLED = "disabled"
MOTORCYCLE = "motorcycle"
LOADING = "loading"
TAXI = "taxi"
CYCLE = "cycle"
NO_WAITING = "noWaiting"
NO_STOPPING = "noStopping"
NO_LOADING = "noLoading"
RED_ROUTE = "redRoute"
CLEARWAY = "clearway"
ZIGZAG = "zigzag"
BUS_STOP = "busStop"
CROSSING = "crossing"
FOOTWAY = "footway"
SUSPENSION = "suspension"
CPZ = "controlledParkingZone"
RPZ = "restrictedParkingZone"
PPA = "permitParkingArea"
OTHER = "other"

REGULATION_TYPES: dict[str, tuple[str, str]] = {
    # Places where waiting is permitted
    "kerbsideParkingPlace": (PERMISSION, STANDARD),
    "kerbsidePaymentParkingPlace": (PERMISSION, PAID),
    "kerbsidePermitParkingPlace": (PERMISSION, PERMIT),
    "kerbsideLimitedWaiting": (PERMISSION, LIMITED_WAITING),
    "kerbsideDisabledBadgeHoldersOnly": (PERMISSION, DISABLED),
    "kerbsideMotorcycleParkingPlace": (PERMISSION, MOTORCYCLE),
    "kerbsideLoadingBay": (PERMISSION, LOADING),
    "kerbsideLoadingBayPassengerSetDownPermitted": (PERMISSION, LOADING),
    "kerbsideLoadingBayPassengerSetDownProhibited": (PERMISSION, LOADING),
    "kerbsideLoadingPlace": (PERMISSION, LOADING),
    "kerbsideLoadingPlacePassengerSetDownPermitted": (PERMISSION, LOADING),
    "kerbsideLoadingPlacePassengerSetDownProhibited": (PERMISSION, LOADING),
    "kerbsideTaxiRank": (PERMISSION, TAXI),
    "miscCycleHireParking": (PERMISSION, CYCLE),
    "miscCycleParking": (PERMISSION, CYCLE),
    "miscTemporaryParkingBay": (PERMISSION, STANDARD),
    # Prohibitions on waiting or stopping
    "kerbsideNoWaiting": (PROHIBITION, NO_WAITING),
    "kerbsideNoStopping": (PROHIBITION, NO_STOPPING),
    "kerbsideSingleRedLines": (PROHIBITION, RED_ROUTE),
    "kerbsideDoubleRedLines": (PROHIBITION, RED_ROUTE),
    "kerbsideRedRouteClearway": (PROHIBITION, RED_ROUTE),
    "kerbsideRedRouteBusStopClearway": (PROHIBITION, BUS_STOP),
    "kerbsideRuralClearway": (PROHIBITION, CLEARWAY),
    "kerbsideUrbanClearway": (PROHIBITION, CLEARWAY),
    "kerbsideSchoolKeepClearYellowZigZagMandatory": (PROHIBITION, ZIGZAG),
    "kerbsideOtherYellowZigZagMandatory": (PROHIBITION, ZIGZAG),
    "kerbsideFootwayParkingProhibited": (PROHIBITION, FOOTWAY),
    "nonOrderKerbsideBusStop": (PROHIBITION, BUS_STOP),
    "nonOrderKerbsidePedestrianCrossing": (PROHIBITION, CROSSING),
    "miscTemporaryParkingRestriction": (PROHIBITION, NO_WAITING),
    # Suspensions
    "miscBaySuspension": (BAY_SUSPENSION, SUSPENSION),
    "miscSuspensionOfParkingRestriction": (RESTRICTION_SUSPENSION, SUSPENSION),
    # Context that never decides legality on its own
    "kerbsideNoLoading": (INFO, NO_LOADING),
    "kerbsideNoLoadingPassengerSetDownPermitted": (INFO, NO_LOADING),
    "kerbsideNoLoadingPassengerSetDownProhibited": (INFO, NO_LOADING),
    "kerbsideFootwayParking": (INFO, FOOTWAY),
    # Zones
    "kerbsideControlledParkingZone": (ZONE, CPZ),
    "kerbsideRestrictedParkingZone": (ZONE, RPZ),
    "kerbsidePermitParkingArea": (ZONE, PPA),
}

PARKING_REGULATION_TYPES = frozenset(REGULATION_TYPES)

# Order reporting points describing something that is not (yet) in force.
PROPOSAL_REPORTING_POINTS = frozenset({"permanentNoticeOfProposal", "ttroTtmoNoticeOfIntention"})
REVOCATION_REPORTING_POINTS = frozenset(
    {"permanentRevocation", "experimentalRevocation", "ttroTtmoRevocation"}
)
TEMPORARY_REPORTING_POINTS = frozenset(
    {
        "ttroTtmoByNotice",
        "ttroTtmoExtension",
        "ttroTtmoNoticeAfterMaking",
        "ttroTtmoNoticeOfIntention",
        "ttroTtmoRevocation",
        "specialEventOrderNoticeOfMaking",
    }
)
REVOKING_ACTION_TYPES = frozenset({"fullRevoke", "partialRevoke"})


def classify(regulation_type: str | None) -> tuple[str, str] | None:
    """Return (role, category) for a parking-relevant regulation type, else None."""
    if regulation_type is None:
        return None
    return REGULATION_TYPES.get(regulation_type)
