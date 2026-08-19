# flutter_background_location_tracker example

This app demonstrates:

- Android and iOS background-location permission recovery;
- route-identifier entry when starting, with whitespace normalization and a
  unique UTC date-time suffix;
- Start, Pause, Resume, and Complete lifecycle controls;
- live status, activity, motion, mock-location, and point evidence;
- latest-only and keep-all track retention;
- recorded-track history with per-route actions;
- MapLibre street-map route display;
- user-named GeoJSON, KML, and GPX export;
- confirmed deletion of a selected completed route.

## Run the example

```sh
flutter pub get
flutter run
```

Use a physical device for background, screen-lock, activity, mock-signal, OEM,
and battery tests. Simulator/emulator success is not production validation.

When **Start** is pressed, the example asks for a route identifier. The plugin
normalizes whitespace to underscores and adds a UTC timestamp suffix before
storing it as `Track.routeId`; for example, `Morning delivery route` becomes
`Morning_delivery_route_20260819_091530_123456`. Recorded-route cards and
default export names use this readable identifier while the internal track ID
continues to manage lifecycle operations.

The retention selector starts with **Keep all** selected. Every completed route
therefore remains in the recorded-route list until the user deletes it or
changes the selector to **Latest only** before starting a new route.

## Android permission setup

The plugin's Android manifest is merged into the example app automatically.
The resulting application manifest must contain the following declarations. A
host application normally does not need to duplicate them, but should verify
its merged release manifest if it uses custom manifest rules:

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

The native package name intentionally remains
`com.samir.flutter_background_location` for upgrade and persisted-session
compatibility.

### Grant the required Android access

The example does not start or resume tracking until
`TrackingPermissionState.canTrackInBackground` is true. The user must grant:

- Location Services enabled;
- **Precise** location;
- Location → **Allow all the time**;
- notifications on Android 13 and later.

Activity Recognition is optional for route capture but required for the full
activity and battery-optimization behavior.

Use this sequence:

1. Open the example and tap **Start** while it is visible.
2. Select **Precise** and **While using the app** in the foreground location
   prompt.
3. On Android 9 and earlier, this foreground grant satisfies the older
   background permission model.
4. On Android 10, accept the separate **Allow all the time** prompt.
5. On Android 11 and later, tap **Open app settings** when instructed, select
   Permissions → Location → **Allow all the time**, and keep **Use precise
   location** enabled.
6. On Android 13 and later, allow notifications for the persistent foreground
   service notification.
7. Return to the example and tap **Start** again. The app rechecks every
   permission before starting native capture.

Android 11 and later do not expose **Allow all the time** in the normal runtime
dialog. Android also ignores a foreground and background location request made
together, so this staged flow is required. Always start the foreground service
from a visible screen after a direct user action.

The app can request access and open Settings, but it cannot grant **Allow all
the time** itself. The user must make that choice.

Official references: [runtime location
permission](https://developer.android.com/develop/sensors-and-location/location/permissions/runtime),
[background location](https://developer.android.com/develop/sensors-and-location/location/permissions/background),
and [foreground services](https://developer.android.com/develop/background-work/services/fgs/launch).

## iOS permission setup

In Xcode, select the Runner target and enable:

**Signing & Capabilities → Background Modes → Location updates**

The example already contains the following values in
`ios/Runner/Info.plist`. A host application must add its own honest,
product-specific usage descriptions:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Location is used to record an active example track.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Location is recorded while an active example track continues in the background.</string>
<key>NSMotionUsageDescription</key>
<string>Motion is used to reduce GPS and battery usage while stationary.</string>
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
</array>
```

`NSLocationWhenInUseUsageDescription` supports the first authorization stage.
`NSLocationAlwaysAndWhenInUseUsageDescription` is required for Always access.
`NSMotionUsageDescription` is required for Core Motion activity recognition,
and `UIBackgroundModes/location` allows active Core Location updates in the
background.

The package supports iOS 13 and later, so it uses the modern
`NSLocationAlwaysAndWhenInUseUsageDescription` key rather than the deprecated
`NSLocationAlwaysUsageDescription` key.

### Grant the required iOS access

The plugin requires Location Services, **Precise Location**, and **Always**
authorization before background tracking starts:

1. Tap **Start** and choose **Allow While Using App**. Do not choose **Allow
   Once** when you intend to enable Always access.
2. Return to the Start flow after the app explains why the active track must
   continue in the background. The plugin then requests Always authorization.
3. Choose **Change to Always Allow** when iOS presents the elevation prompt.
   iOS controls when this prompt appears.
4. If authorization remains When In Use, is denied, or Precise Location is
   disabled, open iOS Settings → this app → Location, select **Always**, and
   enable **Precise Location**.
5. Return to the app and tap **Start** again. Tracking begins only after
   `canTrackInBackground` becomes true.

Do not repeatedly trigger system prompts. Show a clear explanation before the
Always request and respect the user's decision. Motion permission can be denied
without stopping the route, but activity becomes unknown and stationary battery
optimization stays conservative.

The app can request Always authorization, but only the user can approve
**Change to Always Allow** or select Always in iOS Settings.

Official references: [requesting location
authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services),
[`requestAlwaysAuthorization()`](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestalwaysauthorization()),
[background updates](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background),
and [`NSMotionUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmotionusagedescription).

## Permission troubleshooting

If Start remains disabled or throws `TrackingPermissionException`, check:

- `locationServiceEnabled` is true;
- `location` is `LocationPermissionLevel.always`;
- `preciseLocation` is true;
- `notificationGranted` is true on Android;
- `requiresSettings` and `canRequestBackground` for the next UI action;
- iOS has the Location updates background capability and all required
  `Info.plist` keys.

Permissions can be revoked while the app is installed. Recheck them before
every start or resume and after returning from system settings.

## Recorded route actions

Each item under **Recorded tracks** has an overflow menu with these actions:

- **Export GeoJSON**, **Export KML**, and **Export GPX** ask for an editable
  file name and export that selected route;
- **View on map** opens the selected route on the MapLibre street map and
  preserves pause/resume segments as separate lines;
- **Delete** shows a confirmation dialog and permanently removes the selected
  route, its segments, points, health events, lifecycle operations, pending
  commands, and upload-outbox records through SQLite foreign-key cascades.

Export actions are enabled after a route is completed. Delete is enabled only
for terminal routes (completed or failed). Active, paused, interrupted,
starting, and stopping routes remain protected so the UI cannot orphan a
native tracking session or remove a route that can still be resumed.

The same deletion operation is available to host applications:

```dart
await tracking.deleteTrack(completedTrackId);
```

Deletion is permanent. Export or upload a route first when it must be retained
outside the local database.

---

## 🥟 Support this project

> **Did this plugin save you development time or help your application?**
> Your support helps fund maintenance, platform updates, testing on real
> devices, and new features for the Flutter community.

<p align="center">
  <a href="https://buymemomo.com/firantey">
    <img
      src="https://img.shields.io/badge/BUY_ME_A_MOMO-SUPPORT_FIRANTEY-FF6B35?style=for-the-badge&amp;labelColor=7C2D12"
      alt="Support Firantey on Buy Me a MOMO"
      height="44"
    />
  </a>
</p>

<p align="center">
  <strong>💛 One plate of MOMO helps keep this plugin maintained and improving.</strong>
</p>

**Support link:** [buymemomo.com/firantey](https://buymemomo.com/firantey)
