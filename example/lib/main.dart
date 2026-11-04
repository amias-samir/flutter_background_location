import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

import 'history_page.dart';
import 'recorded_tracks_section.dart';
import 'recorded_trips_section.dart';
import 'route_map_page.dart';
import 'route_totals.dart';
import 'tracking_controls.dart';
import 'tracking_dialogs.dart';

typedef ExampleTrackingControllerFactory =
    Future<TrackingController> Function(
      TrackingOwner owner,
      TrackRecordRetentionPolicy retention,
    );

/// The Trip whose current leg is [trackId]. A Trip is active while its leg
/// records and suspended while the leg is paused or interrupted, so Complete
/// Trip looks in both.
Future<Trip?> findOpenTrip(
  MultiDayTripController tracking,
  TrackingOwner owner,
  String trackId,
) async {
  final open = await tracking.listTripPage(
    TripQuery(
      owner: owner,
      limit: 10,
      statuses: const <TripStatus>{TripStatus.active, TripStatus.suspended},
    ),
  );
  for (final trip in open.items) {
    if (trip.currentLegTrackId == trackId) return trip;
  }
  return null;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TrackingExampleApp());
}

class TrackingExampleApp extends StatelessWidget {
  const TrackingExampleApp({super.key, this.controllerFactory});

  final ExampleTrackingControllerFactory? controllerFactory;

  @override
  Widget build(BuildContext context) {
    // Soft ink on a soft grey background: dark slate text and mid-grey
    // labels, white cards with a hairline border, no shadows.
    final colors =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF00796B),
          brightness: Brightness.light,
        ).copyWith(
          onSurface: const Color(0xFF3C4347),
          onSurfaceVariant: const Color(0xFF737A7F),
          surfaceContainerLow: Colors.white,
          surfaceContainerLowest: const Color(0xFFF4F6F5),
        );
    final base = Typography.material2021().black.apply(
      bodyColor: colors.onSurface,
      displayColor: colors.onSurface,
    );
    final textTheme = base.copyWith(
      titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w500),
      titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w500),
      titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w500),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Background location tracker',
      theme: ThemeData(
        colorScheme: colors,
        textTheme: textTheme,
        scaffoldBackgroundColor: colors.surfaceContainerLowest,
        appBarTheme: AppBarTheme(
          backgroundColor: colors.surfaceContainerLowest,
          foregroundColor: colors.onSurface,
          elevation: 0,
          scrolledUnderElevation: 1,
          titleTextStyle: textTheme.titleLarge?.copyWith(
            color: colors.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: colors.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        filledButtonTheme: const FilledButtonThemeData(
          style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, 52))),
        ),
        outlinedButtonTheme: const OutlinedButtonThemeData(
          style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, 52))),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
        bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: colors.surfaceContainerLow,
        ),
        useMaterial3: true,
      ),
      home: TrackingExamplePage(controllerFactory: controllerFactory),
    );
  }
}

class TrackingExamplePage extends StatefulWidget {
  const TrackingExamplePage({super.key, this.controllerFactory});

  final ExampleTrackingControllerFactory? controllerFactory;

  @override
  State<TrackingExamplePage> createState() => _TrackingExamplePageState();
}

class _TrackingExamplePageState extends State<TrackingExamplePage> {
  static const _owner = TrackingOwner(
    userId: 'example-user',
    organizationId: 'example-organization',
  );

  /// Whether this build records and shows diagnostics: debug builds do,
  /// profile and release builds record a clean route and show only it and
  /// its stops ([TrackingConfiguration.recordingDetail]).
  static final _recordsDiagnostics =
      TrackingClient.resolveRecordingDetail(
        const TrackingConfiguration().recordingDetail,
      ) ==
      RouteRecordingDetail.full;

  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  TrackingController? _tracking;
  TrackingSessionSnapshot? _session;
  TrackRecordRetentionPolicy _retention = TrackRecordRetentionPolicy.keepAll;
  TrackingAccuracy _accuracy = TrackingAccuracy.high;
  RouteCaptureIntent _captureIntent = RouteCaptureIntent.adaptive;
  MotionFusionMode _motionFusionMode = MotionFusionMode.platformActivityOnly;
  MultiDayRoutePresentation _routePresentation =
      MultiDayRoutePresentation.separateRecordedParts;

  /// The loaded history and whether a command runs; the history page
  /// listens to it.
  final ValueNotifier<RecordedHistory> _history =
      ValueNotifier<RecordedHistory>(const RecordedHistory(busy: true));
  String? _historyCursor;

  List<Track> get _tracks => _history.value.tracks;
  List<RecordedTripSummary> get _trips => _history.value.trips;
  bool get _busy => _history.value.busy;
  set _busy(bool value) =>
      _history.value = _history.value.copyWith(busy: value);

  @override
  void initState() {
    super.initState();
    unawaited(_openController());
  }

  Future<void> _openController() async {
    await _cancelSubscriptions();
    final previous = _tracking;
    if (previous != null) await previous.dispose();
    try {
      final controller =
          await (widget.controllerFactory?.call(_owner, _retention) ??
              TrackingClient.openWithTrips(
                owner: _owner,
                configuration: TrackingConfiguration(
                  recordRetentionPolicy: _retention,
                ),
              ));
      _tracking = controller;
      _history.value = RecordedHistory(
        tripMode: controller is MultiDayTripController,
        busy: true,
      );
      _subscriptions
        ..add(
          controller.sessionStream.listen((session) {
            if (mounted) setState(() => _session = session);
          }),
        )
        ..add(
          controller.trackHistoryEvents.listen((_) {
            unawaited(_refreshHistory());
          }),
        );
      _session = controller.currentSession;
      await _refreshHistory();
      if (mounted) setState(() => _busy = false);
    } on Object catch (error) {
      _showError(error);
    }
  }

  Future<void> _cancelSubscriptions() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> _run(Future<void> Function() command) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await command();
    } on TrackingException catch (error) {
      _showError('${error.code}: ${error.message}');
      return;
    } on TrackingPermissionException catch (error) {
      _showError(error);
      return;
    } on Object catch (error) {
      _showError(error);
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() => _busy = false);
    _showMessage(error.toString(), error: true);
  }

  /// Shows [message] in a snack bar; [copyable] text, such as an export
  /// path, gets a Copy action.
  void _showMessage(String message, {bool error = false, String? copyable}) {
    if (!mounted) return;
    final colors = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: error ? TextStyle(color: colors.onErrorContainer) : null,
          ),
          backgroundColor: error ? colors.errorContainer : null,
          duration: Duration(seconds: copyable == null ? 4 : 8),
          action: copyable == null
              ? null
              : SnackBarAction(
                  label: 'Copy',
                  onPressed: () => unawaited(
                    Clipboard.setData(ClipboardData(text: copyable)),
                  ),
                ),
        ),
      );
  }

  Future<void> _refreshTracks({bool append = false}) async {
    final tracking = _tracking;
    if (tracking == null) return;
    final page = await tracking.listTrackPage(
      TrackQuery(limit: 25, cursor: append ? _historyCursor : null),
    );
    final totals = <String, RouteTotals>{
      if (tracking is TrackingSummaryController)
        for (final track in page.items)
          track.id: RouteTotals.ofRoute(
            await (tracking as TrackingSummaryController).routeSummary(
              track.id,
            ),
          ),
    };
    if (!mounted) return;
    setState(() {
      _history.value = _history.value.copyWith(
        tripMode: false,
        tracks: append
            ? List<Track>.unmodifiable(<Track>[..._tracks, ...page.items])
            : page.items,
        totals: Map<String, RouteTotals>.unmodifiable(<String, RouteTotals>{
          if (append) ..._history.value.totals,
          ...totals,
        }),
        hasMore: page.hasMore,
      );
      _historyCursor = page.nextCursor;
    });
  }

  Future<void> _refreshTrips({bool append = false}) async {
    final tracking = _tracking;
    if (tracking is! MultiDayTripController) return;
    final tripTracking = tracking as MultiDayTripController;
    final page = await tripTracking.listTripPage(
      TripQuery(
        owner: _owner,
        limit: 25,
        cursor: append ? _historyCursor : null,
      ),
    );
    // Each Trip's details are stored in the route database.
    final summaries = await Future.wait<RecordedTripSummary>(
      page.items.map(
        (trip) async => RecordedTripSummary(
          trip: trip,
          totals: tracking is TrackingSummaryController
              ? RouteTotals.ofTrip(
                  await (tracking as TrackingSummaryController).tripSummary(
                    trip.id,
                  ),
                )
              : null,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _history.value = _history.value.copyWith(
        tripMode: true,
        trips: append
            ? List<RecordedTripSummary>.unmodifiable(<RecordedTripSummary>[
                ..._trips,
                ...summaries,
              ])
            : summaries,
        hasMore: page.nextCursor != null,
      );
      _historyCursor = page.nextCursor;
    });
  }

  Future<void> _refreshHistory({bool append = false}) =>
      _tracking is MultiDayTripController
      ? _refreshTrips(append: append)
      : _refreshTracks(append: append);

  Future<bool> _ensureReady() async {
    final tracking = _tracking!;
    final readiness = await tracking.checkReadiness();
    if (readiness.canStart) return true;
    switch (readiness.nextAction) {
      case TrackingReadinessAction.explainBackgroundLocation:
        if (!mounted) return false;
        final accepted =
            await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Allow background location'),
                content: const Text(
                  'Always location access is required so an active route can '
                  'continue while the screen is locked or another app is open.',
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Not now'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Continue'),
                  ),
                ],
              ),
            ) ??
            false;
        if (accepted) {
          await tracking.acknowledgeReadinessEducation(
            readiness.issues.first.code,
          );
          _showMessage('Tap Start again to request Always access.');
        }
        return false;
      case TrackingReadinessAction.requestForegroundLocation:
      case TrackingReadinessAction.requestBackgroundLocation:
      case TrackingReadinessAction.requestNotification:
      case TrackingReadinessAction.requestActivityRecognition:
        return (await tracking.requestNextPermission()).canStart;
      case TrackingReadinessAction.enableLocationServices:
        await tracking.openSettings(
          TrackingSettingsDestination.locationServices,
        );
        return false;
      case TrackingReadinessAction.enablePreciseLocation:
      case TrackingReadinessAction.openAppSettings:
        await tracking.openSettings(TrackingSettingsDestination.application);
        return false;
      case TrackingReadinessAction.none:
        return true;
      case TrackingReadinessAction.unsupported:
      case TrackingReadinessAction.unknown:
        throw const TrackingNotReadyException(
          code: 'tracking_not_ready',
          message: 'This device cannot satisfy the tracking prerequisites.',
        );
    }
  }

  Future<void> _start() => _run(() async {
    if (!await _ensureReady() || !mounted) return;
    final routeId = await showDialog<String>(
      context: context,
      builder: (_) => const RouteIdentifierDialog(),
    );
    if (routeId == null) return;
    final config = TrackingConfig(
      accuracy: _accuracy,
      captureIntent: _captureIntent,
      motionFusionMode: _motionFusionMode,
      mockLocationPolicy: MockLocationPolicy.flag,
    );
    final tracking = _tracking!;
    if (tracking is MultiDayTripController) {
      await (tracking as MultiDayTripController).startTrip(
        TripStartRequest(
          routeId: routeId,
          config: config,
          dayLabel: 'Day 1',
          routePresentation: _routePresentation,
        ),
      );
    } else {
      await tracking.startNewTrack(
        TrackStartRequest(owner: _owner, routeId: routeId, config: config),
      );
    }
    await _refreshHistory();
  });

  Future<void> _pause() => _run(() async {
    await _tracking!.pauseCurrentTrack(reason: 'example_pause');
    await _refreshHistory();
  });

  Future<void> _resume() => _run(() async {
    if (!await _ensureReady()) return;
    await _tracking!.resumeCurrentTrack();
    await _refreshHistory();
  });

  Future<Trip?> _currentTrip() async {
    final tracking = _tracking;
    final trackId = _session?.currentTrack?.id;
    if (tracking is! MultiDayTripController || trackId == null) return null;
    return findOpenTrip(tracking as MultiDayTripController, _owner, trackId);
  }

  Future<void> _endDay() => _run(() async {
    final tracking = _tracking;
    if (tracking is! MultiDayTripController) return;
    await (tracking as MultiDayTripController).endCurrentDay(
      reason: 'overnight',
    );
    await _refreshHistory();
  });

  Future<void> _complete() async {
    final tracking = _tracking;
    if (tracking is MultiDayTripController) {
      final tripTracking = tracking as MultiDayTripController;
      final trip = await _currentTrip();
      if (trip == null || !mounted) return;
      final confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              icon: const Icon(Icons.flag_rounded),
              title: const Text('Complete the whole Trip?'),
              content: const Text(
                'This closes the current day and marks the multi-day Trip as '
                'finished. You can deliberately continue it later, but the '
                'app will ask for confirmation.',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Complete Trip'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed) return;
      return _run(() async {
        await tripTracking.completeTrip(
          trip.id,
          reason: 'example_trip_completed',
        );
        await _refreshHistory();
      });
    }
    return _run(() async {
      await tracking!.completeCurrentTrack(reason: 'example_completed');
      await _refreshHistory();
    });
  }

  Future<void> _resolveOwnerConflict() async {
    final token = _session?.blockerRecoveryToken;
    if (token == null) return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Pause another owner’s route?'),
            content: const Text(
              'A route started for a different owner is still collecting '
              'locations on this device. Continuing will stop its local '
              'background capture and preserve the route as paused. No '
              'recorded points will be deleted.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.pause_rounded),
                label: const Text('Pause route'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _run(() async {
      await _tracking!.resolveOwnerConflict(
        OwnerConflictResolutionRequest(
          conflictToken: token,
          operationId: DateTime.now().microsecondsSinceEpoch.toString(),
          confirmed: true,
        ),
      );
      await _refreshHistory();
    });
  }

  Future<void> _exportTrack(String trackId, TrackExportFormat format) async {
    final index = _tracks.indexWhere((track) => track.id == trackId);
    final routeName = index < 0 ? trackId : _tracks[index].routeId ?? trackId;
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          ExportNameDialog(format: format, initialFileName: routeName),
    );
    if (name == null) return;
    await _run(() async {
      final result = await _tracking!.exportTrack(
        trackId: trackId,
        format: format,
        fileName: name,
      );
      _showMessage(
        'Exported ${result.pointCount} points to ${result.path}',
        copyable: result.path,
      );
    });
  }

  Future<void> _deleteTrack(Track track) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete recorded route?'),
            content: const Text(
              'This removes its segments and points from the local database.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _run(() async {
      await _tracking!.deleteTrack(track.id);
      await _refreshHistory();
    });
  }

  Future<void> _exportTrip(String tripId, TrackExportFormat format) async {
    final index = _trips.indexWhere((item) => item.trip.id == tripId);
    final routeName = index < 0 ? tripId : _trips[index].trip.routeId ?? tripId;
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          ExportNameDialog(format: format, initialFileName: routeName),
    );
    if (name == null) return;
    await _run(() async {
      final tracking = _tracking! as MultiDayTripController;
      final result = await tracking.exportTrip(
        tripId: tripId,
        format: format,
        fileName: name,
      );
      _showMessage(
        'Exported ${result.pointCount} Trip points to ${result.path}',
        copyable: result.path,
      );
    });
  }

  /// GeoJSON with every point, including rejected ones, and per-fix
  /// diagnostics: accuracy, Doppler speed, native profile and activity age.
  Future<void> _exportTripDiagnostics(String tripId) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => ExportNameDialog(
        format: TrackExportFormat.geoJson,
        initialFileName:
            'diagnostics_${DateTime.now().toUtc().millisecondsSinceEpoch}',
      ),
    );
    if (name == null) return;
    await _run(() async {
      final tracking = _tracking! as MultiDayTripController;
      final result = await tracking.exportTrip(
        tripId: tripId,
        format: TrackExportFormat.geoJson,
        fileName: name,
        options: const TrackExportOptions(
          includeGeoJsonPointFeatures: true,
          includeRejectedPoints: true,
          includeDiagnosticProperties: true,
        ),
      );
      _showMessage(
        'Exported ${result.pointCount} diagnostic points to ${result.path}',
        copyable: result.path,
      );
    });
  }

  /// GPX of the cleaned route view, one file per recorded day. Combined Trip
  /// export takes raw geometry only, so each day exports its own cleaned
  /// view.
  Future<void> _exportTripCleaned(Trip trip) async {
    final tracking = _tracking;
    if (tracking == null || tracking is! TrackingSummaryController) return;
    final summaries = tracking as TrackingSummaryController;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => ExportNameDialog(
        format: TrackExportFormat.gpx,
        initialFileName:
            'cleaned_${DateTime.now().toUtc().millisecondsSinceEpoch}',
      ),
    );
    if (name == null) return;
    await _run(() async {
      final tripTracking = tracking as MultiDayTripController;
      final bundle = await tripTracking.loadTripBundle(trip.id);
      final exported = <String>[];
      var points = 0;
      for (final leg in bundle.legs) {
        final run = await summaries.currentCleanedGeometry(leg.trackId);
        final result = await tracking.exportTrack(
          trackId: leg.trackId,
          format: TrackExportFormat.gpx,
          fileName: bundle.legs.length == 1
              ? name
              : '${name}_day_${leg.legNumber}',
          options: TrackExportOptions(
            geometry: TrackGeometrySelection.derived(run.id),
          ),
        );
        points += result.pointCount;
        exported.add(result.path);
      }
      _showMessage(
        'Exported $points cleaned points to ${exported.join(', ')}',
        copyable: exported.join('\n'),
      );
    });
  }

  Future<void> _continueTrip(Trip trip) async {
    if (!await _ensureReady() || !mounted) return;
    var confirmed = true;
    if (trip.status == TripStatus.completed) {
      confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              icon: const Icon(Icons.add_road_rounded),
              title: const Text('Continue completed Trip?'),
              content: const Text(
                'A new day will be appended to this existing Trip. Its '
                'lifecycle revision will change, while earlier legs remain '
                'immutable.',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Continue Trip'),
                ),
              ],
            ),
          ) ??
          false;
    }
    if (!confirmed) return;
    await _run(() async {
      final tracking = _tracking! as MultiDayTripController;
      await tracking.continueTrip(
        trip.id,
        config: TrackingConfig(
          accuracy: _accuracy,
          captureIntent: trip.captureIntent,
          motionFusionMode: _motionFusionMode,
          mockLocationPolicy: MockLocationPolicy.flag,
        ),
        confirmCompletedTripContinuation: trip.status == TripStatus.completed,
      );
      await _refreshHistory();
    });
  }

  Future<void> _deleteTrip(Trip trip) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.delete_forever_outlined),
            title: const Text('Delete the whole Trip?'),
            content: Text(
              'This permanently removes all ${trip.legCount} day legs, '
              'points, gap evidence, and local Trip records.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete Trip'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _run(() async {
      await (_tracking! as MultiDayTripController).deleteTrip(trip.id);
      await _refreshHistory();
    });
  }

  Future<void> _showDiagnostics() => _run(() async {
    final tracking = _tracking;
    if (tracking is! TrackingDiagnosticsController) return;
    final doctor = await (tracking as TrackingDiagnosticsController)
        .runSetupDoctor();
    final failures = doctor.findings
        .where((finding) => finding.applicable && !finding.passed)
        .map((finding) => finding.code)
        .join(', ');
    _showMessage(
      doctor.passed
          ? 'Setup doctor: all applicable checks passed.'
          : 'Setup doctor findings: $failures',
      error: !doctor.passed,
    );
  });

  Future<void> _changeRetention(TrackRecordRetentionPolicy value) async {
    if (value == _retention || _session?.currentTrack != null) return;
    setState(() {
      _retention = value;
      _busy = true;
    });
    await _openController();
  }

  Future<void> _changeAccuracy(TrackingAccuracy value) async {
    if (value == _accuracy) return;
    setState(() => _accuracy = value);
    if (value != TrackingAccuracy.precised || !mounted) return;

    final openSettings =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Precised tracking uses more battery'),
            content: const Text(
              'For the densest Android location updates, exclude this app '
              'from battery optimization and choose Unrestricted or No '
              'restrictions if your device provides that option. Setting '
              'names vary by manufacturer. This is optional and increases '
              'battery use.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Open battery settings'),
              ),
            ],
          ),
        ) ??
        false;
    if (openSettings && mounted) await _openBatteryOptimizationSettings();
  }

  Future<void> _openBatteryOptimizationSettings() => _run(() async {
    final result = await _tracking!.openSettings(
      TrackingSettingsDestination.batteryOptimization,
    );
    _showMessage(
      result.opened
          ? 'In Android battery settings, allow this app to ignore battery '
                'optimization or select Unrestricted/No restrictions.'
          : result.supported
          ? 'Battery optimization settings could not be opened.'
          : 'Battery optimization settings are not available on this platform.',
    );
  });

  @override
  void dispose() {
    unawaited(_cancelSubscriptions());
    _history.dispose();
    final tracking = _tracking;
    if (tracking != null) unawaited(tracking.dispose().catchError((_) {}));
    super.dispose();
  }

  Future<void> _openHistory() => Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => RecordedHistoryPage(
        history: _history,
        onRefresh: _refreshHistory,
        listBuilder: _historyList,
      ),
    ),
  );

  Future<void> _openTrackMap(Track track) => Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => TrackMapPage(
        tracking: _tracking!,
        track: track,
        showDiagnostics: _recordsDiagnostics,
      ),
    ),
  );

  Future<void> _openTripMap(Trip trip) => Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => TripMapPage(
        tracking: _tracking! as MultiDayTripController,
        trip: trip,
        showDiagnostics: _recordsDiagnostics,
      ),
    ),
  );

  /// The history page's list, from the home page's current [history].
  Widget _historyList(BuildContext context, RecordedHistory history) {
    final busy = history.busy;
    final tracking = _tracking;
    if (history.tripMode) {
      return RecordedTripsSection(
        trips: history.trips,
        hasMore: history.hasMore,
        showDiagnostics: _recordsDiagnostics,
        onLoadMore: busy ? null : () => _refreshTrips(append: true),
        onViewMap: busy ? null : _openTripMap,
        onContinue: busy ? null : _continueTrip,
        onExport: busy ? null : _exportTrip,
        onExportDiagnostics: busy || !_recordsDiagnostics
            ? null
            : _exportTripDiagnostics,
        onExportCleaned: busy || tracking is! TrackingSummaryController
            ? null
            : _exportTripCleaned,
        onDelete: busy ? null : _deleteTrip,
      );
    }
    return RecordedTracksSection(
      tracks: history.tracks,
      totals: history.totals,
      hasMore: history.hasMore,
      showDiagnostics: _recordsDiagnostics,
      onLoadMore: busy ? null : () => _refreshTracks(append: true),
      onViewMap: busy || tracking == null ? null : _openTrackMap,
      onExport: busy ? null : _exportTrack,
      onDelete: busy ? null : _deleteTrack,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tracking = _tracking;
    final tripMode = tracking is MultiDayTripController;
    final actions = _session?.allowedActions;
    final canConfigure = !_busy && _session?.currentTrack == null;
    final hasOwnerConflict = _session?.blockerCode == 'owner_scope_conflict';
    final settingsEnabled = !_busy && tracking != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Location tracker'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Setup doctor',
            onPressed: settingsEnabled ? _showDiagnostics : null,
            icon: const Icon(Icons.health_and_safety_outlined),
          ),
          PopupMenuButton<TrackingSettingsDestination>(
            tooltip: 'Settings',
            enabled: settingsEnabled,
            onSelected: (destination) =>
                destination == TrackingSettingsDestination.batteryOptimization
                ? _openBatteryOptimizationSettings()
                : tracking!.openSettings(destination),
            itemBuilder: (_) => <PopupMenuEntry<TrackingSettingsDestination>>[
              const PopupMenuItem(
                value: TrackingSettingsDestination.application,
                child: ListTile(
                  leading: Icon(Icons.settings_outlined),
                  title: Text('App settings'),
                ),
              ),
              if (_accuracy == TrackingAccuracy.precised)
                const PopupMenuItem(
                  value: TrackingSettingsDestination.batteryOptimization,
                  child: ListTile(
                    leading: Icon(Icons.battery_saver_outlined),
                    title: Text('Battery settings'),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _busy
              ? const LinearProgressIndicator(minHeight: 2)
              : const SizedBox(height: 2),
        ),
      ),
      // Everything fits on one screen; it scrolls only when it cannot, on
      // a very small screen or with large text.
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: math.max(0, constraints.maxHeight - 24),
                  ),
                  // A min-size column takes at least the screen's height
                  // and spreads its free space between the groups.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          TrackingStatusCard(
                            session: _session,
                            showDiagnostics: _recordsDiagnostics,
                          ),
                          if (hasOwnerConflict) ...<Widget>[
                            const SizedBox(height: 8),
                            OwnerConflictCard(
                              onResolve: _busy ? null : _resolveOwnerConflict,
                            ),
                          ],
                          const SizedBox(height: 24),
                          TrackingConfigurationControls(
                            retention: _retention,
                            accuracy: _accuracy,
                            captureIntent: _captureIntent,
                            routePresentation: _routePresentation,
                            motionFusionMode: _motionFusionMode,
                            enabled: canConfigure,
                            onRetentionChanged: _changeRetention,
                            onAccuracyChanged: _changeAccuracy,
                            onCaptureIntentChanged: (value) =>
                                setState(() => _captureIntent = value),
                            onRoutePresentationChanged: (value) =>
                                setState(() => _routePresentation = value),
                            onMotionFusionModeChanged: (value) =>
                                setState(() => _motionFusionMode = value),
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                      RecordedHistoryTile(
                        history: _history.value,
                        onTap: tracking == null ? null : _openHistory,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: TrackingActionPanel(
                canStart: !_busy && actions?.canStartNew == true,
                canPause: !_busy && actions?.canPause == true,
                canResume: !_busy && actions?.canResume == true,
                canComplete: !_busy && actions?.canComplete == true,
                canEndDay: tripMode && !_busy && actions?.canComplete == true,
                tripMode: tripMode,
                onStart: _start,
                onPause: _pause,
                onResume: _resume,
                onComplete: _complete,
                onEndDay: _endDay,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
