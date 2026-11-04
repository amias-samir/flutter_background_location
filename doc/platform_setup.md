# Platform setup

Everything the host app declares and the permission flow each platform needs.
The [README](../README.md#platform-setup) has the short version.

## Android

### Manifest

The plugin manifest is merged into the host app automatically. It contributes
the complete permission and component set shown below, so applications normally
must not duplicate it. Verify these entries in the merged release manifest if
your build customizes manifest merging:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-feature
        android:name="android.hardware.location.gps"
        android:required="false" />

    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />

    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
    <uses-permission android:name="com.google.android.gms.permission.ACTIVITY_RECOGNITION" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission
        android:name="android.permission.WRITE_EXTERNAL_STORAGE"
        android:maxSdkVersion="28" />

    <application>
        <service
            android:name="com.samir.flutter_background_location.LocationTrackingService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="location"
            android:stopWithTask="false" />

        <receiver
            android:name="com.samir.flutter_background_location.ActivityRecognitionReceiver"
            android:enabled="true"
            android:exported="false" />

        <receiver
            android:name="com.samir.flutter_background_location.TrackingBootReceiver"
            android:enabled="true"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
            </intent-filter>
        </receiver>
    </application>
</manifest>
```

Do not remove `ACCESS_BACKGROUND_LOCATION` or the `location` foreground-service
type. The package intentionally keeps the native
`com.samir.flutter_background_location` namespace for upgrade compatibility.

### Required runtime state

`startTrack()` and `resumeTrack()` refuse to start native background capture
until all required conditions are true:

- Location Services are enabled.
- **Precise** foreground location is granted.
- Background location is reported as **Allow all the time**.
- Notification permission is granted on Android 13 and later.
- The command is initiated while an Activity is visible.

Activity Recognition permission is requested on Android 10 and later. If it is
denied, route capture can continue, but activity classification becomes unknown,
the battery-saving stationary transition remains conservative, and steps are
not counted.

### Permission sequence by Android version

1. Start the flow only after the user taps a visible Start/Enable Tracking
   control. The plugin requests `ACCESS_COARSE_LOCATION` and
   `ACCESS_FINE_LOCATION` together. On Android 12 and later the user must select
   **Precise**, not Approximate.
2. On Android 9 and earlier, the older permission model grants background
   capability with the foreground location grant.
3. On Android 10, the plugin makes the separate background permission request;
   the system dialog can offer **Allow all the time**.
4. On Android 11 and later, the runtime dialog cannot grant **Allow all the
   time**. When `requiresSettings` is true, show an educational screen, call
   `openAppSettings()`, and ask the user to choose Location → **Allow all the
   time** and keep **Use precise location** enabled.
5. On Android 13 and later, the user must also allow notifications so the
   foreground-service notification remains visible.
6. After the app resumes from Settings, read permissions again. Enable Start
   only when `state.canTrackInBackground` is true.

Android 11 and later ignore a combined foreground/background runtime request,
which is why permission elevation must be incremental. Android 12 and later
also restrict foreground-service starts from the background. On Android 14 and
later, the system validates location access when the location foreground
service starts. Always call `startTrack()` from a visible screen after a clear
user action.

Android does not let an app grant **Allow all the time** on the user's behalf.
The plugin can request or open the correct Settings page, but the user must make
the final permission choice.

See Android's official guides for [runtime location
permission](https://developer.android.com/develop/sensors-and-location/location/permissions/runtime),
[background location](https://developer.android.com/develop/sensors-and-location/location/permissions/background),
and [foreground-service startup](https://developer.android.com/develop/background-work/services/fgs/launch).

Google Play applies additional policy requirements to background location and
foreground services. The host application is responsible for its prominent
disclosure, privacy policy, Data safety answers, permission flow, Play Console
declaration, and demonstrating that background access is core functionality.

## iOS

### Background capability

In Xcode, enable:

**Runner target → Signing & Capabilities → Background Modes → Location
updates**

This adds `location` to `UIBackgroundModes`. The plugin validates the background
mode before starting.

### `Info.plist`

Add all of these keys to the host application's `Info.plist`. Replace the sample
strings with clear, product-specific explanations of what is recorded, when it
continues in the background, and how the user stops it:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Location is used to record your route while a trip is active.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Your active trip continues to record when the app is in the background.</string>
<key>NSMotionUsageDescription</key>
<string>Motion helps adjust location frequency and reduce battery use.</string>
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
</array>
```

`NSLocationWhenInUseUsageDescription` is required for the first authorization
stage. `NSLocationAlwaysAndWhenInUseUsageDescription` is required before the
plugin can request Always access. `NSMotionUsageDescription` is required for
`CMMotionActivityManager` and the step count; without motion access, tracking
remains on the conservative moving profile and steps are not counted. Mention
step counting in the string when your app shows steps.

The deprecated `NSLocationAlwaysUsageDescription` key is not used because this
package supports iOS 13 and later and checks the modern
`NSLocationAlwaysAndWhenInUseUsageDescription` key.

### Required runtime state and permission sequence

The plugin requires Location Services, **Precise Location**, and **Always**
authorization before starting background tracking:

1. After an explicit user action, call `permissions(request: true)`. When the
   status is not determined, iOS presents the When In Use prompt using
   `NSLocationWhenInUseUsageDescription`.
2. The user must first choose **Allow While Using App**. **Allow Once** is not
   enough for elevation because iOS can ignore the immediate Always request
   after a temporary grant.
3. Explain why the active route must continue with the screen locked or app in
   the background. When `canRequestBackground` is true, call
   `permissions(request: true)` again. The plugin calls
   `requestAlwaysAuthorization()`.
4. The user must choose **Change to Always Allow** when iOS presents the
   elevation prompt. The timing and wording of system prompts are controlled by
   iOS.
5. If the user keeps When In Use, denies access, or disables Precise Location,
   direct them to Settings and recheck when the app becomes active.
6. Start or resume only when `state.canTrackInBackground` is true.

Do not loop permission requests or present an Always prompt without your own
educational UI. Users can change authorization or Precise Location at any time,
so recheck before every start/resume and handle later revocation.

iOS does not let an app grant Always authorization itself. The plugin requests
the elevation, but only the user can approve **Change to Always Allow** or select
Always in Settings.

See Apple's official documentation for [requesting location
authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services),
[`requestAlwaysAuthorization()`](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestalwaysauthorization()),
[background location updates](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background),
and [`NSMotionUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmotionusagedescription).

### Active, paused, and terminated behavior

The native location service runs only while a route is active:

| Route state | Android | iOS |
|---|---|---|
| Active | Foreground service and location/activity requests run | `CLLocationManager` runs; iOS 17+ also holds a `CLBackgroundActivitySession` |
| Paused | Requests, notification, and service stop; the route remains resumable | Location, motion, and background-activity sessions stop; the route remains resumable |
| Resumed | A foreground service and native requests start again | Location, motion, and a new background-activity session start again |
| Completed | Native capture and the service stop, and native active-session state is cleared | All native updates/sessions stop, and native active-session state is cleared |

Putting an active app in the background or locking the screen is not a pause.
With Always + Precise authorization and `UIBackgroundModes/location`, the
active iOS manager continues collecting and journals fixes even if Flutter is
temporarily suspended. The native manager is process-scoped, so rebuilding a
Flutter engine or scene does not label the route interrupted.

On Android, active tracking holds a short-scoped partial wake lock for the
duration of native capture and releases it on Pause, End day, Complete, service
failure, interruption, or service destruction. Motion fusion prefers wake-up
step, significant-motion, accelerometer, gyro, and rotation-vector sensors when
the device provides them, which helps screen-off and pocketed routes keep fresh
motion evidence. The wake lock does not improve satellite visibility; users may
still need to disable aggressive OEM battery restrictions for long precise
routes.

User force-quit is different from minimizing. iOS stops standard continuous
location updates when the user swipes the app away, and an application cannot
override that decision. After a later launch, the plugin reports the route as
interrupted and requires an explicit resume; it never silently marks that route
complete. See Apple's [`startUpdatingLocation()`
documentation](https://developer.apple.com/documentation/corelocation/cllocationmanager/startupdatinglocation())
and [`CLBackgroundActivitySession`](https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession-3mzv3).

For applications that accept reduced, OS-controlled sampling in exchange for
best-effort process relaunch, opt into the distinct significant-change mode:

```dart
const config = TrackingConfig(
  iosTerminationRecoveryMode:
      IosTerminationRecoveryMode.significantChange,
);
```

This mode is not equivalent to continuous GPS. On a relaunch it preserves the
same track identity, reports `recoveredFromTermination`, and labels the
possible missing interval instead of inventing points. The default
`IosTerminationRecoveryMode.interrupted` keeps continuous tracking semantics
and requires manual Resume after termination. User force-quit remains
non-recoverable in both modes until the user opens the app. A host that creates
its Flutter engine lazily can call
`FlutterBackgroundLocationPlugin.prepareTerminationRecovery()` from its iOS
Core Location launch path before attaching UI; recovered capture also restarts
motion fusion so activity evidence does not remain stale after relaunch.
Physical qualification is still required for every supported device/OS bucket
before making a recovery claim.
