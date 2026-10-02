import Foundation
import Testing

@testable import LocisKit

// Reference dates in 2026: Thu 1 Oct, Fri 2, Sat 3, Sun 4, Mon 5, Tue 6, Wed 7 Oct.

@Suite("Whole-stay evaluation")
struct IntervalTests {
    let daytimeYellow = noWaiting(cond: time([period(monSat, [("08:00", "18:30")])]))

    @Test func fullyAllowedInterval() {
        let result = evaluate(bay(), stay("2026-10-05 14:00", "2026-10-05 17:00"))
        #expect(result.status == .allowedFree)
        #expect(result.confidence == .high)
        #expect(!result.paymentRequired)
        #expect(result.segments.count == 1)
    }

    @Test func fullyProhibitedInterval() {
        let result = evaluate(noWaiting(), stay("2026-10-05 14:00", "2026-10-05 17:00"))
        #expect(result.status == .prohibited)
        #expect(result.reasons.first == "No waiting")
    }

    @Test func restrictionStartsDuringStay() {
        let result = evaluate(daytimeYellow, stay("2026-10-05 07:00", "2026-10-05 09:00"))
        #expect(result.status == .prohibited)
        #expect(result.segments.map(\.status) == [.allowedFree, .prohibited])
        #expect(result.segments[1].interval.start == london("2026-10-05 08:00"))
    }

    @Test func restrictionEndsDuringStay() {
        let result = evaluate(daytimeYellow, stay("2026-10-05 18:00", "2026-10-05 20:00"))
        #expect(result.status == .prohibited)
        #expect(seconds(result, .prohibited) == 1800)
    }

    @Test func arrivingExactlyWhenRestrictionEndsIsAllowed() {
        let result = evaluate(daytimeYellow, stay("2026-10-05 18:30", "2026-10-05 23:00"))
        #expect(result.status == .allowedFree)
        // Allowed only because the recorded restriction is not in force.
        #expect(result.confidence == .medium)
    }

    @Test func leavingExactlyWhenRestrictionStartsIsAllowed() {
        let result = evaluate(daytimeYellow, stay("2026-10-05 06:00", "2026-10-05 08:00"))
        #expect(result.status == .allowedFree)
    }

    @Test func multipleTimePeriodsInADay() {
        let zigzag = feature(
            reg: "kerbsideSchoolKeepClearYellowZigZagMandatory", role: "prohibition", cat: "zigzag",
            cond: time([period(monFri, [("08:00", "09:30"), ("14:30", "16:00")])]))
        #expect(evaluate(zigzag, stay("2026-10-05 10:00", "2026-10-05 14:00")).status == .allowedFree)
        #expect(evaluate(zigzag, stay("2026-10-05 10:00", "2026-10-05 15:00")).status == .prohibited)
        #expect(evaluate(zigzag, stay("2026-10-05 09:00", "2026-10-05 10:00")).status == .prohibited)
    }

    @Test func weekdayAndWeekend() {
        let weekdays = noWaiting(cond: time([period(monFri, [("08:00", "18:00")])]))
        #expect(evaluate(weekdays, stay("2026-10-02 10:00", "2026-10-02 11:00")).status == .prohibited)  // Friday
        #expect(evaluate(weekdays, stay("2026-10-03 10:00", "2026-10-03 11:00")).status == .allowedFree)  // Saturday
        #expect(evaluate(weekdays, stay("2026-10-04 10:00", "2026-10-04 11:00")).status == .allowedFree)  // Sunday
    }

    @Test func overnightRestrictionAsTwoWindows() {
        let overnight = noWaiting(cond: time([period(everyDay, [("22:00", "24:00"), ("00:00", "06:00")])]))
        #expect(evaluate(overnight, stay("2026-10-05 21:00", "2026-10-05 23:00")).status == .prohibited)
        #expect(evaluate(overnight, stay("2026-10-05 23:30", "2026-10-06 05:00")).status == .prohibited)
        #expect(evaluate(overnight, stay("2026-10-05 06:00", "2026-10-05 22:00")).status == .allowedFree)
    }

    @Test func windowWrappingMidnightBelongsToTheDayItStarts() {
        // "Monday 22:00 to 06:00": runs into Tuesday morning, not Monday morning.
        let mondayNight = noWaiting(cond: time([period([1], [("22:00", "06:00")])]))
        #expect(evaluate(mondayNight, stay("2026-10-06 03:00", "2026-10-06 04:00")).status == .prohibited)  // Tue 03:00
        #expect(evaluate(mondayNight, stay("2026-10-05 03:00", "2026-10-05 04:00")).status == .allowedFree)  // Mon 03:00
        #expect(evaluate(mondayNight, stay("2026-10-05 23:00", "2026-10-05 23:30")).status == .prohibited)
        #expect(evaluate(mondayNight, stay("2026-10-06 23:00", "2026-10-06 23:30")).status == .allowedFree)
    }

    @Test func stayCrossingIntoAnotherWeekday() {
        let paid = paidBay(cond: time([period(monFri, [("08:30", "18:30")])], rate: perQuarterHour(1.0)))
        // Friday 17:00 to Saturday 10:00: only Friday 17:00-18:30 is chargeable.
        let result = evaluate(paid, stay("2026-10-02 17:00", "2026-10-03 10:00"))
        #expect(result.status == .allowedPaid)
        #expect(result.chargeableSeconds == 5400)
        #expect(result.estimatedCost?.amount == 6)
    }

    @Test func stayCrossingIntoARestrictedWeekday() {
        // Sunday night into Monday morning, restriction starts Monday 08:00.
        let result = evaluate(daytimeYellow, stay("2026-10-04 20:00", "2026-10-05 09:00"))
        #expect(result.status == .prohibited)
        #expect(seconds(result, .prohibited) == 3600)
    }

    @Test func invalidStaysAreRejected() {
        #expect(throws: Stay.ValidationError.departureNotAfterArrival) {
            try Stay(arrival: london("2026-10-05 14:00"), departure: london("2026-10-05 14:00"))
        }
        #expect(throws: Stay.ValidationError.departureNotAfterArrival) {
            try Stay(arrival: london("2026-10-05 14:00"), departure: london("2026-10-05 13:00"))
        }
        #expect(throws: Stay.ValidationError.tooLong) {
            try Stay(arrival: london("2026-10-05 14:00"), departure: london("2026-12-05 14:00"))
        }
    }
}

@Suite("Stay limits and payment")
struct LimitsAndPaymentTests {
    let limited = feature(
        reg: "kerbsideLimitedWaiting", cat: "limitedWaiting",
        cond: time([period(monSat, [("08:00", "18:00")], extra: ["maxStay": 7200, "noReturn": 3600])]))

    @Test func maxStayExceeded() {
        let result = evaluate(limited, stay("2026-10-05 10:00", "2026-10-05 12:30"))
        #expect(result.status == .prohibited)
        #expect(result.reasons.first?.contains("maximum stay of 2 hours") == true)
    }

    @Test func maxStayExactlyMet() {
        let result = evaluate(limited, stay("2026-10-05 10:00", "2026-10-05 12:00"))
        #expect(result.status == .allowedFree)
        #expect(result.limits.maxStay == 7200)
    }

    @Test func noReturnIsReported() {
        let result = evaluate(limited, stay("2026-10-05 10:00", "2026-10-05 11:00"))
        #expect(result.limits.noReturn == 3600)
    }

    @Test func onlyTimeInsideControlledHoursCountsTowardsMaxStay() {
        // 17:00 to 21:00 is four hours, but only one of them is limited.
        let result = evaluate(limited, stay("2026-10-05 17:00", "2026-10-05 21:00"))
        #expect(result.status == .allowedFree)
    }

    @Test func stayThroughTwoLimitedPeriodsIsNotConfirmed() {
        // One hour on Monday evening and one on Tuesday morning: within the limit
        // each day, but the vehicle never left.
        let result = evaluate(limited, stay("2026-10-05 17:00", "2026-10-06 09:00"))
        #expect(result.status == .conditional)
    }

    @Test func paidPeriodWithCost() {
        let paid = paidBay(cond: time([period(monSat, [("08:30", "18:30")])], rate: perQuarterHour(1.2)))
        let result = evaluate(paid, stay("2026-10-05 14:00", "2026-10-05 17:00"))
        #expect(result.status == .allowedPaid)
        #expect(result.paymentRequired)
        #expect(result.chargeableSeconds == 3 * 3600)
        #expect(result.estimatedCost?.amount == Decimal(string: "14.40"))
        #expect(result.estimatedCost?.hourlyRate == Decimal(string: "4.80"))
        #expect(result.costNote == nil)
    }

    @Test func partlyPaidPartlyUnrestricted() {
        // The brief's example: paid Saturday 08:30-13:30, stay Saturday 12:00-15:00.
        let paid = paidBay(cond: time([period([6], [("08:30", "13:30")])], rate: perQuarterHour(1.2)))
        let result = evaluate(paid, stay("2026-10-03 12:00", "2026-10-03 15:00"))
        #expect(result.status == .allowedPaid)
        #expect(result.segments.map(\.status) == [.allowedPaid, .allowedFree])
        #expect(result.chargeableSeconds == 5400)
        #expect(result.estimatedCost?.amount == Decimal(string: "7.20"))
        #expect(result.reasons.contains { $0.contains("outside charging hours") })
    }

    @Test func paidBayOutsideHoursIsFree() {
        let paid = paidBay(cond: time([period(monSat, [("08:30", "18:30")])], rate: perQuarterHour(1.2)))
        let result = evaluate(paid, stay("2026-10-04 10:00", "2026-10-04 12:00"))  // Sunday
        #expect(result.status == .allowedFree)
        #expect(!result.paymentRequired)
        #expect(result.confidence == .medium)
    }

    @Test func paidBayWithoutTariffNeverInventsAPrice() {
        let paid = paidBay(cond: time([period(monSat, [("08:30", "18:30")])]))
        let result = evaluate(paid, stay("2026-10-05 14:00", "2026-10-05 17:00"))
        #expect(result.status == .allowedPaid)
        #expect(result.estimatedCost == nil)
        #expect(result.costNote == CostCalculator.unavailable)
    }

    @Test func limitedWaitingWithoutARecordedLimitIsNotConfirmed() {
        let noLimit = feature(reg: "kerbsideLimitedWaiting", cat: "limitedWaiting", cond: time([period(monSat, [("08:00", "18:00")])]))
        #expect(evaluate(noLimit, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .conditional)
        // Outside its hours the limit is not in question.
        #expect(evaluate(noLimit, stay("2026-10-05 19:00", "2026-10-05 20:00")).status == .allowedFree)
    }

    @Test func unreadableStayLimitIsNotConfirmed() {
        let unreadable = feature(
            reg: "kerbsideLimitedWaiting", cat: "limitedWaiting",
            cond: time([period(monSat, [("08:00", "18:00")], extra: ["unsupported": ["maxStay"]])]))
        #expect(evaluate(unreadable, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .conditional)
    }
}

@Suite("Who the rule applies to")
struct EligibilityTests {
    @Test func permitOnlyBayIsConditional() {
        let permitBay = feature(
            reg: "kerbsidePermitParkingPlace", cat: "permit",
            cond: allOf(time([period(monFri, [("08:30", "18:30")])]), permit()))
        let during = evaluate(permitBay, stay("2026-10-05 10:00", "2026-10-05 11:00"))
        #expect(during.status == .conditional)
        #expect(during.unresolvedConditions == ["Resident permit required (Zone D)"])
        // Outside permit hours anyone may park.
        #expect(evaluate(permitBay, stay("2026-10-05 19:00", "2026-10-05 21:00")).status == .allowedFree)
    }

    @Test func permitBayWithNoPermitDescribedStillNeedsAPermit() {
        let permitBay = feature(reg: "kerbsidePermitParkingPlace", cat: "permit", cond: always)
        #expect(evaluate(permitBay, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .conditional)
    }

    @Test func disabledBayDependsOnBlueBadge() {
        let disabled = feature(reg: "kerbsideDisabledBadgeHoldersOnly", cat: "disabled", cond: always)
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        #expect(evaluate(disabled, period).status == .specialist)
        #expect(evaluate(disabled, period, profile: VehicleProfile(blueBadge: true)).status == .allowedFree)
    }

    @Test func blueBadgeConditionInTheTree() {
        let bay = bay(cond: allOf(always, ["driver": "disabledWithPermit"]))
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        #expect(evaluate(bay, period).status == .prohibited)
        #expect(evaluate(bay, period, profile: VehicleProfile(blueBadge: true)).status == .allowedFree)
    }

    @Test func wrongVehicleType() {
        let carsOnly = bay(cond: allOf(always, vehicle("car")))
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        #expect(evaluate(carsOnly, period).status == .allowedFree)
        #expect(evaluate(carsOnly, period, profile: VehicleProfile(vehicleType: .van)).status == .prohibited)
        #expect(evaluate(carsOnly, period, profile: VehicleProfile(vehicleType: .motorcycle)).status == .prohibited)
        // "Other" could be anything, so it is never assumed eligible.
        #expect(evaluate(carsOnly, period, profile: VehicleProfile(vehicleType: .other)).status == .unknown)
    }

    @Test func motorcycleBay() {
        let bay = feature(reg: "kerbsideMotorcycleParkingPlace", cat: "motorcycle", cond: always)
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        #expect(evaluate(bay, period).status == .specialist)
        #expect(evaluate(bay, period, profile: VehicleProfile(vehicleType: .motorcycle)).status == .allowedFree)
    }

    @Test func loadingBayIsNeverParkingAndIsNotConfirmedOutsideHours() {
        let loading = feature(reg: "kerbsideLoadingBay", cat: "loading", cond: time([period(monSat, [("07:00", "19:00")])]))
        #expect(evaluate(loading, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .specialist)
        #expect(evaluate(loading, stay("2026-10-05 20:00", "2026-10-05 21:00")).status == .conditional)
    }

    @Test func nestedAndConditionSet() {
        // Applies to cars, on weekdays, with a permit.
        let bay = feature(
            reg: "kerbsidePermitParkingPlace", cat: "permit",
            cond: allOf(time([period(monFri)]), allOf(vehicle("car"), permit("business"))))
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        #expect(evaluate(bay, period).status == .conditional)
        // A van fails the vehicle condition, so the permit question never arises.
        #expect(evaluate(bay, period, profile: VehicleProfile(vehicleType: .van)).status == .prohibited)
    }

    @Test func nestedOrConditionSet() {
        // Business permit holders OR Blue Badge holders.
        let bay = feature(
            reg: "kerbsidePermitParkingPlace", cat: "permit",
            cond: allOf(time([period(monFri)]), anyOf(permit("business"), ["occupant": ["disabled": true]])))
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        #expect(evaluate(bay, period).status == .conditional)
        #expect(evaluate(bay, period, profile: VehicleProfile(blueBadge: true)).status == .allowedFree)
    }

    @Test func exclusiveOrConditionSet() {
        let bay = bay(cond: allOf(always, oneOf(vehicle("car"), vehicle("motorVehicle"))))
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        // A car matches both branches, so "exactly one" fails; a van matches one.
        #expect(evaluate(bay, period).status == .prohibited)
        #expect(evaluate(bay, period, profile: VehicleProfile(vehicleType: .van)).status == .allowedFree)
    }

    @Test func negatedConditionExemptsAVehicle() {
        // No waiting for everyone except motorcycles.
        let restriction = noWaiting(cond: allOf(always, not(vehicle("motorcycle"))))
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        #expect(evaluate(restriction, period).status == .prohibited)
        // The data exempts the rider, but an exemption with nothing positively
        // allowing parking is not shown as available.
        let rider = evaluate(restriction, period, profile: VehicleProfile(vehicleType: .motorcycle))
        #expect(rider.status == .conditional)
        #expect(rider.reasons.first?.contains("does not apply to you") == true)
    }

    @Test func exemptionFromARestrictionOnABayLeavesTheBayUsable() {
        // A paid bay with a restriction that applies to goods vehicles only.
        let paid = paidBay(cond: time([period(monSat, [("08:30", "18:30")])], rate: perQuarterHour(1.0)))
        let goodsOnly = noWaiting("goods", cond: allOf(always, vehicle("goodsVehicle")))
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        #expect(evaluate(paid, with: [goodsOnly], period).status == .allowedPaid)
        #expect(evaluate(paid, with: [goodsOnly], period, profile: VehicleProfile(vehicleType: .van)).status == .prohibited)
    }

    @Test func unknownVehicleUseIsNotAssumedToExcludeTheUser() {
        let restriction = noWaiting(cond: allOf(always, ["vehicle": ["usage": "somethingNewInV5"]]))
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        #expect(evaluate(restriction, period).status == .unknown)
        let police = noWaiting(cond: allOf(always, ["vehicle": ["usage": "policeVehicle"]]))
        #expect(evaluate(police, period).status == .conditional)
    }

    @Test func prohibitionExceptPermitHoldersIsConditional() {
        let restriction = noWaiting(cond: allOf(always, not(permit())))
        #expect(evaluate(restriction, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .conditional)
    }

    @Test func negatedTimeCondition() {
        // In force at all times except Sundays.
        let restriction = noWaiting(cond: allOf(always, not(time([period([7])]))))
        #expect(evaluate(restriction, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .prohibited)
        #expect(evaluate(restriction, stay("2026-10-04 10:00", "2026-10-04 11:00")).status == .allowedFree)
    }
}

@Suite("Overlapping, temporary and suspended rules")
struct OverlapTests {
    let paid = paidBay(cond: time([period(monSat, [("08:30", "18:30")])], rate: perQuarterHour(1.0)))

    @Test func prohibitionIsNotHiddenByAParkingPlace() {
        let peak = noWaiting("peak", cond: time([period(monFri, [("16:00", "19:00")])]))
        #expect(evaluate(paid, with: [peak], stay("2026-10-05 10:00", "2026-10-05 12:00")).status == .allowedPaid)
        let blocked = evaluate(paid, with: [peak], stay("2026-10-05 15:00", "2026-10-05 17:00"))
        #expect(blocked.status == .prohibited)
        #expect(blocked.applicableRuleIDs.contains("peak"))
        // After 18:30 the bay is uncontrolled but the restriction runs to 19:00.
        #expect(evaluate(paid, with: [peak], stay("2026-10-05 18:30", "2026-10-05 19:30")).status == .prohibited)
        #expect(evaluate(paid, with: [peak], stay("2026-10-05 19:00", "2026-10-05 21:00")).status == .allowedFree)
    }

    @Test func activeSuspensionOverridesParking() {
        let suspension = feature(
            "suspension", reg: "miscBaySuspension", role: "baySuspension", cat: "suspension",
            cond: time([period([3], [("06:00", "20:00")])]))
        let wednesday = evaluate(paid, with: [suspension], stay("2026-10-07 10:00", "2026-10-07 11:00"))
        #expect(wednesday.status == .prohibited)
        #expect(wednesday.reasons.first == "Bay suspended")
        #expect(evaluate(paid, with: [suspension], stay("2026-10-06 10:00", "2026-10-06 11:00")).status == .allowedPaid)
        // Suspended from 06:00 although the bay's own hours start at 08:30.
        #expect(evaluate(paid, with: [suspension], stay("2026-10-07 06:30", "2026-10-07 07:30")).status == .prohibited)
    }

    @Test func temporaryRestrictionSupersedesTheBayItNames() {
        let free = bay()
        let works = noWaiting(
            "works",
            cond: time(
                [period(monFri, [("08:00", "17:00")])], start: "2026-10-01T00:00:00Z", end: "2026-10-31T00:00:00Z"),
            ["temporary": true, "overrides": [free.prov], "from": "2026-10-01"])
        #expect(evaluate(free, with: [works], stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .prohibited)
        #expect(evaluate(free, with: [works], stay("2026-10-05 18:00", "2026-10-05 20:00")).status == .allowedFree)
        // Once the temporary order has ended it takes no part at all.
        let afterwards = evaluate(free, with: [works], stay("2026-11-09 10:00", "2026-11-09 11:00"))
        #expect(afterwards.status == .allowedFree)
        #expect(afterwards.confidence == .high)
    }

    @Test func expiredOrderAloneIsUnknownNotFree() {
        let works = noWaiting(cond: time(start: "2026-09-01T00:00:00Z", end: "2026-09-30T00:00:00Z"))
        #expect(evaluate(works, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .unknown)
    }

    @Test func orderNotYetInForceIsUnknownNotFree() {
        let future = paidBay(cond: time([period(monSat, [("08:30", "18:30")])], start: "2030-01-01T00:00:00Z"), ["from": "2030-01-01"])
        #expect(evaluate(future, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .unknown)
        #expect(evaluate(future, stay("2026-10-04 10:00", "2026-10-04 11:00")).status == .unknown)
    }

    @Test func orderComingIntoForceDuringTheStay() {
        let restriction = noWaiting(cond: time(start: "2026-10-06T00:00:00Z"), ["from": "2026-10-06"])
        let free = bay("bay")
        let result = evaluate(free, with: [restriction], stay("2026-10-05 20:00", "2026-10-06 08:00"))
        #expect(result.status == .prohibited)
        // BST: the order starts at 00:00 UTC, which is 01:00 in London.
        #expect(seconds(result, .prohibited) == 7 * 3600)
    }

    @Test func plannedRestrictionIsFlaggedNotEnforced() {
        let planned = noWaiting("planned", cond: time(start: "2026-10-01T00:00:00Z"), ["lifecycle": "intended", "temporary": true])
        let result = evaluate(bay(), with: [planned], stay("2026-10-05 10:00", "2026-10-05 11:00"))
        #expect(result.status == .conditional)
        #expect(result.reasons.first == "A temporary restriction is planned here")
    }

    @Test func revocationOnTheKerbMakesItUnknown() {
        let revocation = bay("revocation", cond: always, ["lifecycle": "revocation", "from": "2026-06-01"])
        #expect(evaluate(bay(), with: [revocation], stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .unknown)
        // Before the revocation takes effect the bay stands.
        #expect(evaluate(bay(), with: [revocation], stay("2026-05-04 10:00", "2026-05-04 11:00")).status == .allowedFree)
    }

    @Test func sharedUseBayOffersTheUsableGrant() {
        let permitBay = feature(
            "permit", reg: "kerbsidePermitParkingPlace", cat: "permit",
            cond: allOf(time([period(monFri, [("08:30", "18:30")])]), permit()))
        let result = evaluate(paid, with: [permitBay], stay("2026-10-05 10:00", "2026-10-05 11:00"))
        #expect(result.status == .allowedPaid)
        #expect(result.confidence == .medium)
    }

    @Test func conflictingBayTypesAreNotResolvedByGuessing() {
        let disabled = feature("disabled", reg: "kerbsideDisabledBadgeHoldersOnly", cat: "disabled", cond: always)
        let result = evaluate(paid, with: [disabled], stay("2026-10-05 10:00", "2026-10-05 11:00"))
        #expect(result.status == .unknown)
        #expect(result.confidence == .unknown)
    }

    @Test func suspensionOfARestrictionLiftsOnlyTheRestrictionItNames() {
        let yellow = noWaiting()
        let named = feature(
            "lift", reg: "miscSuspensionOfParkingRestriction", role: "restrictionSuspension", cat: "suspension",
            cond: always, ["overrides": [yellow.prov]])
        let unnamed = feature(
            "lift", reg: "miscSuspensionOfParkingRestriction", role: "restrictionSuspension", cat: "suspension",
            cond: always)
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        // With the restriction lifted nothing positive remains, so it is unknown, not free.
        #expect(evaluate(yellow, with: [named], period).status == .unknown)
        #expect(evaluate(yellow, with: [unnamed], period).status == .prohibited)
    }

    @Test func temporaryOrderThatExemptsTheUserDoesNotWipeOutTheBay() {
        // A temporary restriction on goods vehicles names the paid bay it overrides.
        // For a car it must not turn the paid bay into free parking.
        let temporary = noWaiting(
            "temp", cond: allOf(time(start: "2026-10-01T00:00:00Z"), vehicle("goodsVehicle")),
            ["temporary": true, "overrides": [paid.prov]])
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        #expect(evaluate(paid, with: [temporary], period).status == .allowedPaid)
        #expect(evaluate(paid, with: [temporary], period, profile: VehicleProfile(vehicleType: .van)).status == .prohibited)
    }

    @Test func plannedOrderDoesNotOverrideAnything() {
        let planned = noWaiting(
            "planned", cond: time(start: "2026-10-01T00:00:00Z"),
            ["lifecycle": "intended", "temporary": true, "overrides": [paid.prov]])
        let result = evaluate(paid, with: [planned], stay("2026-10-05 10:00", "2026-10-05 11:00"))
        #expect(result.status == .conditional)
        #expect(result.reasons.first == "A temporary restriction is planned here")
    }

    @Test func twoGrantsThatDisagreeTakeTheMoreDemandingReading() {
        // An older "free bay" record and a newer "paid, 2 hours" record on one kerb.
        let free = bay("old")
        let newer = paidBay(cond: time([period(monSat, [("08:30", "18:30")], extra: ["maxStay": 7200])], rate: perQuarterHour(1.0)))
        let result = evaluate(newer, with: [free], stay("2026-10-05 10:00", "2026-10-05 11:00"))
        #expect(result.status == .allowedPaid)
        #expect(result.limits.maxStay == 7200)
        #expect(result.estimatedCost == nil)  // two grants: no single tariff to quote
        #expect(result.confidence == .medium)
        // The same from the other record's point of view.
        #expect(evaluate(free, with: [newer], stay("2026-10-05 10:00", "2026-10-05 13:00")).status == .prohibited)  // over 2 hours
    }

    @Test func expiredTimeConditionInsideAnAndMakesTheOrderAbsent() {
        // AND of a current condition and one whose dates have passed: the order
        // no longer exists, which is unknown, not "outside hours".
        let lapsed = bay(cond: allOf(always, time(start: "2026-01-01T00:00:00Z", end: "2026-06-01T00:00:00Z")))
        #expect(evaluate(lapsed, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .unknown)
        // OR: one branch still current keeps the order alive.
        let alive = bay(cond: anyOf(always, time(start: "2026-01-01T00:00:00Z", end: "2026-06-01T00:00:00Z")))
        #expect(evaluate(alive, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .allowedFree)
    }

    @Test func parkingAreaDoesNotGrantParkingOnAKerbButAnAreaRestrictionApplies() {
        let period = stay("2026-10-05 10:00", "2026-10-05 11:00")
        // A loading restriction on the kerb says nothing about waiting; a paid
        // parking *area* drawn over it must not turn the kerb into a paid bay.
        let noLoading = feature(reg: "kerbsideNoLoading", role: "info", cat: "noLoading", cond: always)
        let paidArea = paidBay("area", cond: always, ["geomQuality": "area"])
        #expect(evaluate(noLoading, with: [paidArea], period).status == .unknown)
        // A no-waiting area does apply to a bay inside it.
        let restrictedArea = noWaiting("area", cond: always, ["geomQuality": "area"])
        #expect(evaluate(bay(), with: [restrictedArea], period).status == .prohibited)
    }

    @Test func partialOverlapIsAppliedToTheWholeSectionAndFlagged() {
        let junction = noWaiting("junction")
        let free = relinked(bay(), related: ["junction"], partial: ["junction"])
        let result = ParkingRulesEngine(holidays: testHolidays).evaluate(
            free, context: [free.id: free, "junction": junction], stay: stay("2026-10-05 10:00", "2026-10-05 11:00"),
            profile: .standard)
        #expect(result.status == .prohibited)
        #expect(result.reasons.first == "No waiting (recorded for part of this section)")
    }
}

@Suite("Missing, unsupported and uncertain data")
struct SafetyTests {
    let hour = stay("2026-10-05 10:00", "2026-10-05 11:00")

    @Test func missingRelatedRuleIsUnknown() {
        let orphan = relinked(bay(), related: ["not-loaded"])
        let result = ParkingRulesEngine(holidays: testHolidays).evaluate(
            orphan, context: [orphan.id: orphan], stay: hour, profile: .standard)
        #expect(result.status == .unknown)
    }

    @Test func incompleteDataIsUnknown() {
        #expect(evaluate(bay(), hour, incomplete: true).status == .unknown)
    }

    @Test func loadingRestrictionAloneSaysNothingAboutWaiting() {
        let noLoading = feature(reg: "kerbsideNoLoading", role: "info", cat: "noLoading", cond: always)
        #expect(evaluate(noLoading, hour).status == .unknown)
    }

    @Test func unsupportedConditionIsUnknown() {
        let odd = bay(cond: allOf(always, ["other": "Except when the barrier is closed"]))
        let result = evaluate(odd, hour)
        #expect(result.status == .unknown)
        #expect(result.reasons.contains { $0.contains("barrier is closed") })
    }

    @Test func unsupportedConditionThatCannotMatterIsIgnored() {
        // Weekdays AND <uninterpretable>: on a Sunday the AND is false whatever
        // the unknown part means.
        let restriction = noWaiting(cond: allOf(time([period(monFri)]), ["other": "when lights flash"]))
        #expect(evaluate(restriction, stay("2026-10-04 10:00", "2026-10-04 11:00")).status == .allowedFree)
        #expect(evaluate(restriction, hour).status == .unknown)
    }

    @Test func unsupportedRecurrenceIsUnknown() {
        let market = paidBay(cond: time([period(nil, [("08:00", "18:00")], extra: ["unsupported": ["specialDay:marketDay"]])]))
        #expect(evaluate(market, hour).status == .unknown)
    }

    @Test func unknownRegulationTypeIsUnknown() {
        let offList = feature(reg: "offList", role: "unsupported", cat: "other", cond: always)
        #expect(evaluate(offList, hour).status == .unknown)
        // A role this app version has never heard of decodes as unsupported.
        let newer = feature(role: "somethingNew", cond: always)
        #expect(newer.role == .unsupported)
        #expect(evaluate(newer, hour).status == .unknown)
    }

    @Test func unknownRuleOverlappingABayMakesItUnknown() {
        let offList = feature("mystery", reg: "offList", role: "unsupported", cat: "other", cond: always)
        #expect(evaluate(bay(), with: [offList], hour).status == .unknown)
    }

    @Test func dynamicAndPlaceholderRulesAreUnknown() {
        #expect(evaluate(bay(cond: always, ["issues": ["dynamic"]]), hour).status == .unknown)
        #expect(evaluate(bay(cond: always, ["issues": ["placeholder"]]), hour).status == .unknown)
    }

    @Test func unreadableConditionNodeIsUnsupportedNotDropped() {
        let strange = bay(cond: allOf(always, ["somethingNew": ["x": 1]]))
        #expect(evaluate(strange, hour).status == .unknown)
        let badTime = bay(cond: ["time": ["start": "not a date"]])
        #expect(evaluate(badTime, hour).status == .unknown)
    }

    @Test func unreadableTimeWindowsAreUnknownNotNever() {
        // A restriction whose hours cannot be read must not look permanently off.
        for times in [[[28800]], [[28800, 99999]], [[-5, 3600]], [[28800, 28800]]] as [[[Int]]] {
            let restriction = noWaiting(cond: time([["times": times, "days": [["dow": everyDay]]]]))
            #expect(evaluate(restriction, hour).status == .unknown, "\(times)")
        }
        let allDay = noWaiting(cond: time([["times": [[0, 0]]]]))
        #expect(evaluate(allDay, hour).status == .prohibited)
        let noDays = noWaiting(cond: time([["days": [Any]()]]))
        #expect(evaluate(noDays, hour).status == .unknown)
    }

    @Test func emptyConditionSetsAreUnknown() {
        #expect(evaluate(noWaiting(cond: ["op": "and", "items": [Any]()]), hour).status == .unknown)
        #expect(evaluate(bay(cond: ["op": "or", "items": [Any]()]), hour).status == .unknown)
        #expect(evaluate(bay(cond: ["op": "xor", "items": [Any]()]), hour).status == .unknown)
    }

    @Test func zoneIsNeverEvaluatedAsAKerb() {
        let zone = feature(reg: "kerbsideControlledParkingZone", role: "zone", cat: "controlledParkingZone", cond: always)
        #expect(evaluate(zone, hour).status == .unknown)
    }

    @Test func centrelineGeometryLowersConfidence() {
        let centre = noWaiting(cond: always, ["geomQuality": "centreline"])
        #expect(evaluate(centre, hour).confidence == .medium)
        let freeCentre = bay(cond: always, ["geomQuality": "centreline"])
        #expect(evaluate(freeCentre, hour).status == .allowedFree)
        #expect(evaluate(freeCentre, hour).confidence == .medium)
    }

    @Test func lowConfidenceIsNeverShownAsAvailable() {
        // Centreline geometry + only "restriction not in force" + a partial overlap.
        let other = noWaiting("other", cond: time([period([7])]))
        let weak = relinked(
            noWaiting(cond: time([period([7])]), ["geomQuality": "centreline"]), related: ["other"], partial: ["other"])
        let result = ParkingRulesEngine(holidays: testHolidays).evaluate(
            weak, context: [weak.id: weak, "other": other], stay: hour, profile: .standard)
        #expect(result.status == .unknown)
        #expect(result.confidence == .unknown)
        #expect(result.estimatedCost == nil)
    }

    @Test func legacyNestingCapsConfidence() {
        let legacy = bay(cond: always, ["issues": ["legacyConditionNesting"]])
        #expect(evaluate(legacy, hour).confidence == .medium)
    }
}

@Suite("Calendar edge cases")
struct CalendarTests {
    @Test func clocksGoingBackRepeatAnHour() {
        // Sunday 25 October 2026: 02:00 BST becomes 01:00 GMT, so 01:00-02:00 happens twice.
        let restriction = noWaiting(cond: time([period(everyDay, [("01:30", "02:30")])]))
        let arrival = london("2026-10-25 00:30")  // BST
        let departure = london("2026-10-25 03:00")  // GMT
        #expect(departure.timeIntervalSince(arrival) == 3.5 * 3600)
        let result = evaluate(restriction, try! Stay(arrival: arrival, departure: departure))
        #expect(result.status == .prohibited)
        // In force 01:30-02:00 BST, then again 01:30-02:30 GMT.
        #expect(seconds(result, .prohibited) == 5400)
    }

    @Test func clocksGoingForwardSkipAnHour() {
        // Sunday 29 March 2026: 01:00 GMT becomes 02:00 BST.
        let limited = feature(
            reg: "kerbsideLimitedWaiting", cat: "limitedWaiting",
            cond: time([period(everyDay, [("00:00", "06:00")], extra: ["maxStay": 7200])]))
        // 00:30 to 03:30 on the clock is only two real hours.
        let result = evaluate(limited, stay("2026-03-29 00:30", "2026-03-29 03:30"))
        #expect(result.status == .allowedFree)
        let longer = evaluate(limited, stay("2026-03-29 00:30", "2026-03-29 03:31"))
        #expect(longer.status == .prohibited)
    }

    @Test func morningRestrictionOnAClockChangeDay() {
        let restriction = noWaiting(cond: time([period(everyDay, [("08:00", "09:00")])]))
        for day in ["2026-03-29", "2026-10-25"] {
            let result = evaluate(restriction, stay("\(day) 07:00", "\(day) 10:00"))
            #expect(seconds(result, .prohibited) == 3600)
            #expect(result.segments.first { $0.status == .prohibited }?.interval.start == london("\(day) 08:00"))
        }
    }

    @Test func utcValidityStartIsComparedAsAnInstant() {
        // 08:00 BST on 5 October is 07:00 UTC.
        let restriction = noWaiting(cond: time(start: "2026-10-05T07:00:00Z"))
        let bay = bay("bay")
        let result = evaluate(bay, with: [restriction], stay("2026-10-05 07:00", "2026-10-05 09:00"))
        #expect(result.segments.map(\.status) == [.allowedFree, .prohibited])
        #expect(result.segments[1].interval.start == london("2026-10-05 08:00"))
    }

    @Test func bankHolidayException() {
        let paid = paidBay(
            cond: time(
                [period(monSat, [("08:30", "18:30")])],
                except: [["special": [["type": "publicHoliday", "intersect": false]]]],
                rate: perQuarterHour(1.2)))
        // Christmas Day 2026 is a Friday.
        #expect(evaluate(paid, stay("2026-12-25 10:00", "2026-12-25 12:00")).status == .allowedFree)
        #expect(evaluate(paid, stay("2026-12-18 10:00", "2026-12-18 12:00")).status == .allowedPaid)
    }

    @Test func bankHolidayBeyondThePublishedCalendarIsUnknown() {
        let paid = paidBay(
            cond: time(
                [period(monSat, [("08:30", "18:30")])],
                except: [["special": [["type": "publicHoliday", "intersect": false]]]]))
        #expect(evaluate(paid, stay("2031-12-25 10:00", "2031-12-25 12:00")).status == .unknown)
    }

    @Test func specialDayIntersectingWithDayRules() {
        // Applies on bank holidays that are also Mondays.
        let restriction = noWaiting(
            cond: time([period([1], extra: ["special": [["type": "publicHoliday", "intersect": true]]])]))
        #expect(evaluate(restriction, stay("2026-05-04 10:00", "2026-05-04 11:00")).status == .prohibited)  // bank holiday Monday
        #expect(evaluate(restriction, stay("2026-05-11 10:00", "2026-05-11 11:00")).status == .allowedFree)  // ordinary Monday
        #expect(evaluate(restriction, stay("2026-12-25 10:00", "2026-12-25 11:00")).status == .allowedFree)  // holiday, Friday
    }

    @Test func monthAndNthWeekdayRules() {
        let firstMondays = noWaiting(cond: time([["days": [["dow": [1], "instance": 1]]]]))
        #expect(evaluate(firstMondays, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .prohibited)
        #expect(evaluate(firstMondays, stay("2026-10-12 10:00", "2026-10-12 11:00")).status == .allowedFree)
        let summer = noWaiting(cond: time([["days": [["months": [6, 7, 8]]]]]))
        #expect(evaluate(summer, stay("2026-07-06 10:00", "2026-07-06 11:00")).status == .prohibited)
        #expect(evaluate(summer, stay("2026-10-05 10:00", "2026-10-05 11:00")).status == .allowedFree)
    }

    @Test func periodDateBoundsAreRespected() {
        let seasonal = noWaiting(
            cond: time([["from": "2026-10-05T11:00:00Z", "to": "2026-10-05T12:00:00Z"]]))  // 12:00-13:00 BST
        let result = evaluate(seasonal, stay("2026-10-05 11:00", "2026-10-05 14:00"))
        #expect(seconds(result, .prohibited) == 3600)
    }

    @Test func descriptionsReadNaturally() {
        #expect(Describe.days([1, 2, 3, 4, 5]) == "Mon\u{2013}Fri")
        #expect(Describe.days([1, 2, 3, 4, 5, 6, 7]) == "Every day")
        #expect(Describe.days([6, 7]) == "Sat, Sun")
        #expect(Describe.duration(7200) == "2 hours")
        #expect(Describe.duration(5400) == "1 hr 30 min")
        #expect(Describe.duration(1200) == "20 minutes")
        let node = try! LocisDecoding.decoder().decode(
            ConditionNode.self,
            from: JSONSerialization.data(withJSONObject: time([period(monFri, [("08:30", "18:30")]), period([6], [("08:30", "13:30")])])))
        #expect(Describe.schedule(node) == ["Mon\u{2013}Fri 08:30\u{2013}18:30", "Sat 08:30\u{2013}13:30"])
    }
}

@Suite("Publishing habits found in real data")
struct RealWorldEncodingTests {
    let hour = stay("2026-10-05 10:00", "2026-10-05 11:00")
    let badge = VehicleProfile(blueBadge: true)

    /// OR(NOT(any vehicle), Blue Badge up to 3 hours, loading up to 40 minutes),
    /// as rewritten by the pipeline.
    var concessions: JSON {
        [
            "concessions": [
                allOf(["occupant": ["disabled": true]], ["time": ["start": "2020-01-01T00:00:00Z", "valid": [["maxStay": 10800]]]]),
                allOf(["access": ["loadingAndUnloading"]], ["time": ["start": "2020-01-01T00:00:00Z", "maxStay": 2400]]),
            ]
        ]
    }

    @Test func noStoppingExceptBusesPublishedAsBusOnly() {
        // Literally "applies to buses". The description says who it really exempts.
        let stop = feature(
            reg: "kerbsideNoStopping", role: "prohibition", cat: "noStopping", cond: allOf(always, vehicle("bus")),
            ["desc": "No stopping except buses"])
        #expect(evaluate(stop, hour).status == .prohibited)
        #expect(evaluate(stop, hour).reasons.first == "No stopping")
        // A service vehicle named with no description at all is treated the same.
        let stand = feature(
            reg: "nonOrderKerbsideBusStop", role: "prohibition", cat: "busStop", cond: allOf(always, vehicle("bus")),
            ["desc": "Bus Stand"])
        #expect(evaluate(stand, hour).status == .prohibited)
        let rank = feature(reg: "kerbsideNoWaiting", role: "prohibition", cat: "noWaiting", cond: allOf(always, vehicle("taxi")))
        #expect(evaluate(rank, hour).status == .prohibited)
    }

    @Test func genuineVehicleSpecificRestrictionIsNotTreatedAsInverted() {
        // A lorry ban really does apply only to lorries: amber for a car, never red or green.
        let lorryBan = noWaiting(cond: allOf(always, vehicle("heavyGoodsVehicle")), ["desc": "No waiting by heavy goods vehicles"])
        #expect(evaluate(lorryBan, hour).status == .conditional)
        // Correctly published exemptions (with a negation) are left as they are.
        let correct = noWaiting(cond: allOf(always, not(vehicle("motorcycle"))), ["desc": "No waiting except motorcycles"])
        #expect(evaluate(correct, hour).status == .prohibited)
        #expect(evaluate(correct, hour, profile: VehicleProfile(vehicleType: .motorcycle)).status == .conditional)
    }

    @Test func restrictionWithAnExemptionListAppliesToEveryone() {
        let yellow = noWaiting(cond: allOf(always, concessions), ["issues": ["exemptionList"]])
        let result = evaluate(yellow, hour)
        #expect(result.status == .prohibited)
        #expect(result.confidence == .medium)
        // The concessions are shown but not applied, even to a Blue Badge holder.
        #expect(evaluate(yellow, hour, profile: badge).status == .prohibited)
        let lines = Describe.eligibility(yellow.cond)
        #expect(lines.contains("Concession recorded (not applied by the app): Blue Badge holders, up to 3 hours"))
        #expect(lines.contains("Concession recorded (not applied by the app): loading and unloading, up to 40 minutes"))
    }

    @Test func bayWithAnExemptionListStaysUsable() {
        let paid = paidBay(
            cond: allOf(time([period(monSat, [("08:30", "18:30")], extra: ["maxStay": 14400])]), concessions),
            ["issues": ["exemptionList"]])
        let result = evaluate(paid, hour)
        #expect(result.status == .allowedPaid)
        // The concession's own stay limit must not replace the bay's.
        #expect(result.limits.maxStay == 14400)
        let permitBay = feature(
            reg: "kerbsidePermitParkingPlace", cat: "permit", cond: allOf(time([period(monSat)]), permit(), concessions))
        #expect(evaluate(permitBay, hour).status == .conditional)
        let disabled = feature(
            reg: "kerbsideDisabledBadgeHoldersOnly", cat: "disabled", cond: allOf(always, ["occupant": ["disabled": true]], concessions))
        #expect(evaluate(disabled, hour).status == .specialist)
        #expect(evaluate(disabled, hour, profile: badge).status == .allowedFree)
    }

    @Test func unreadableConcessionListIsUnknown() {
        #expect(evaluate(noWaiting(cond: allOf(always, ["concessions": "oops"])), hour).status == .unknown)
    }

    @Test func electricVehicleBayIsConditionalNotAvailable() {
        let electric = bay(cond: allOf(time([period(everyDay, extra: ["maxStay": 10800])]), ["vehicle": ["fuel": ["electric"]]]))
        let result = evaluate(electric, hour)
        #expect(result.status == .conditional)
        #expect(result.reasons.first?.hasPrefix("For electric vehicles only") == true)
        // A fuel condition the app does not understand is unknown.
        let diesel = bay(cond: allOf(always, ["vehicle": ["fuel": ["diesel"]]]))
        #expect(evaluate(diesel, hour).status == .unknown)
        // A restriction that exempts electric vehicles still restricts everyone the app knows about.
        let exceptElectric = noWaiting(cond: allOf(always, not(["vehicle": ["fuel": ["electric"]]])))
        #expect(evaluate(exceptElectric, hour).status == .conditional)
    }

    @Test func kerbWithNoRuleInForceIsFlagged() {
        let ended = noWaiting(cond: time(start: "2026-09-01T00:00:00Z", end: "2026-09-30T00:00:00Z"))
        #expect(evaluate(ended, hour).noRuleInForce)
        #expect(!evaluate(noWaiting(), hour).noRuleInForce)
        // In force for only part of the stay: still drawn.
        let starts = noWaiting(cond: time(start: "2026-10-05T09:30:00Z"))  // 10:30 in London
        #expect(!evaluate(starts, hour).noRuleInForce)
    }
}
