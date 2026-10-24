package com.samir.flutter_background_location

import com.google.android.gms.location.Granularity
import com.google.android.gms.location.Priority
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocationRequestPlanTest {
    private val moving = TrackingStateStore.PROFILE_MOVING
    private val stationary = TrackingStateStore.PROFILE_STATIONARY

    private fun configuration(vararg values: Pair<String, Any>) = TrackingConfiguration.fromMap(
        mapOf(
            "desiredAccuracy" to "precised",
            "movingIntervalMs" to 5_000,
            "movingDistanceFilterMeters" to 5,
            "stationaryIntervalMs" to 20_000,
            "stationaryDistanceFilterMeters" to 20,
            "turnCaptureDegrees" to 45,
        ) + values,
    )

    @Test
    fun policyOneTurnCaptureKeepsTheProviderDistanceFilter() {
        val plan = LocationRequestPlan.forProfile(moving, configuration(), batteryLow = false)
        assertEquals(
            LocationRequestPlan(
                priority = Priority.PRIORITY_HIGH_ACCURACY,
                providerIntervalMs = 1_000L,
                minUpdateIntervalMs = 1_000L,
                maxUpdateDelayMs = 5_000L,
                maxUpdateAgeMs = 0L,
                minUpdateDistanceMeters = 5f,
                granularity = Granularity.GRANULARITY_FINE,
                waitForAccurateLocation = true,
                sampler = LocationRequestPlan.Sampler(5_000L, 45f, 5f),
            ),
            plan,
        )
    }

    @Test
    fun policyOneWithoutTurnsRequestsTheInterval() {
        val plan = LocationRequestPlan.forProfile(
            moving,
            configuration("turnCaptureDegrees" to 0),
            batteryLow = false,
        )
        assertEquals(5_000L, plan.providerIntervalMs)
        assertEquals(2_500L, plan.minUpdateIntervalMs)
        assertEquals(5f, plan.minUpdateDistanceMeters)
        assertNull(plan.sampler)
    }

    @Test
    fun samplingPolicyTwoSamplesAnUnfilteredOneHertzStream() {
        val plan = LocationRequestPlan.forProfile(
            moving,
            configuration("samplingPolicyVersion" to 2),
            batteryLow = false,
        )
        assertEquals(
            LocationRequestPlan(
                priority = Priority.PRIORITY_HIGH_ACCURACY,
                providerIntervalMs = 1_000L,
                minUpdateIntervalMs = 1_000L,
                maxUpdateDelayMs = 5_000L,
                maxUpdateAgeMs = 0L,
                minUpdateDistanceMeters = 0f,
                granularity = Granularity.GRANULARITY_FINE,
                waitForAccurateLocation = true,
                sampler = LocationRequestPlan.Sampler(5_000L, 45f, 5f),
            ),
            plan,
        )
        // A low battery changes nothing: the batch is already one interval.
        assertEquals(
            plan,
            LocationRequestPlan.forProfile(
                moving,
                configuration("samplingPolicyVersion" to 2),
                batteryLow = true,
            ),
        )
    }

    @Test
    fun samplingPolicyTwoWithTurnsOffKeepsTheIntervalSampler() {
        val plan = LocationRequestPlan.forProfile(
            moving,
            configuration("samplingPolicyVersion" to 2, "turnCaptureDegrees" to 0),
            batteryLow = false,
        )
        assertEquals(0f, plan.minUpdateDistanceMeters)
        assertEquals(LocationRequestPlan.Sampler(5_000L, 0f, 5f), plan.sampler)
    }

    @Test
    fun samplingPolicyTwoLeavesTheStationaryProfileAndOtherAccuraciesAlone() {
        val versionOne = configuration()
        val versionTwo = configuration("samplingPolicyVersion" to 2)
        for (batteryLow in listOf(false, true)) {
            assertEquals(
                LocationRequestPlan.forProfile(stationary, versionOne, batteryLow),
                LocationRequestPlan.forProfile(stationary, versionTwo, batteryLow),
            )
            for (accuracy in listOf("medium", "balanced", "low", "lowPower", "passive")) {
                assertEquals(
                    accuracy,
                    LocationRequestPlan.forProfile(
                        moving,
                        configuration("desiredAccuracy" to accuracy),
                        batteryLow,
                    ),
                    LocationRequestPlan.forProfile(
                        moving,
                        configuration("desiredAccuracy" to accuracy, "samplingPolicyVersion" to 2),
                        batteryLow,
                    ),
                )
            }
        }
        val stationaryPlan = LocationRequestPlan.forProfile(stationary, versionTwo, false)
        assertEquals(20_000L, stationaryPlan.providerIntervalMs)
        assertEquals(20f, stationaryPlan.minUpdateDistanceMeters)
        assertEquals(40_000L, stationaryPlan.maxUpdateDelayMs)
        assertEquals(Granularity.GRANULARITY_PERMISSION_LEVEL, stationaryPlan.granularity)
        assertNull(stationaryPlan.sampler)
    }

    @Test
    fun aOneSecondMovingIntervalNeedsNoSampler() {
        val plan = LocationRequestPlan.forProfile(
            moving,
            configuration("samplingPolicyVersion" to 2, "movingIntervalMs" to 1_000),
            batteryLow = false,
        )
        assertEquals(1_000L, plan.providerIntervalMs)
        assertEquals(5f, plan.minUpdateDistanceMeters)
        assertNull(plan.sampler)
    }

    @Test
    fun balancedCaptureBatchesLongerUnlessTheBatteryIsLow() {
        val balanced = configuration("desiredAccuracy" to "medium")
        val plan = LocationRequestPlan.forProfile(moving, balanced, batteryLow = false)
        assertEquals(Priority.PRIORITY_BALANCED_POWER_ACCURACY, plan.priority)
        assertEquals(10_000L, plan.maxUpdateDelayMs)
        assertEquals(5_000L, plan.maxUpdateAgeMs)
        assertEquals(false, plan.waitForAccurateLocation)
        assertEquals(5_000L, LocationRequestPlan.forProfile(moving, balanced, true).maxUpdateDelayMs)

        // An explicit travel intent keeps high fidelity at any accuracy.
        val walking = configuration("desiredAccuracy" to "medium", "captureIntent" to "walking")
        val intentPlan = LocationRequestPlan.forProfile(moving, walking, batteryLow = false)
        assertEquals(5_000L, intentPlan.maxUpdateDelayMs)
        assertEquals(Granularity.GRANULARITY_FINE, intentPlan.granularity)
    }

    @Test
    fun accuracyNamesMapToPriorities() {
        listOf("best", "high", "navigation", "precise", "precised", "HIGH").forEach {
            assertEquals(it, Priority.PRIORITY_HIGH_ACCURACY, LocationRequestPlan.priorityFor(it))
        }
        listOf("low", "lowPower", "low_power").forEach {
            assertEquals(it, Priority.PRIORITY_LOW_POWER, LocationRequestPlan.priorityFor(it))
        }
        assertEquals(Priority.PRIORITY_PASSIVE, LocationRequestPlan.priorityFor("passive"))
        assertEquals(
            Priority.PRIORITY_BALANCED_POWER_ACCURACY,
            LocationRequestPlan.priorityFor("medium"),
        )
    }
}
