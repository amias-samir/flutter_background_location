# flutter_background_location example

This app demonstrates permission recovery, start, pause, next-session resume,
completion, live status/activity/mock evidence, and GeoJSON/KML/GPX export.

Before running on iOS, enable the Runner target's **Background Modes → Location
updates** capability. Usage descriptions and `UIBackgroundModes` are already in
the example `Info.plist`.

On Android 11+, the app may direct you to app settings to enable **Allow all the
time** after foreground location has been granted.

```sh
flutter run
```

Use a physical device for background, screen-lock, activity, mock-signal, and
battery tests. Simulator/emulator success is not production validation.
