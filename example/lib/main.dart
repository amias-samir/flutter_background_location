import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

import 'recorded_tracks_section.dart';
import 'route_map_page.dart';
import 'tracking_controls.dart';
import 'tracking_dialogs.dart';

typedef ExampleTrackingControllerFactory =
    Future<TrackingController> Function(
      TrackingOwner owner,
      TrackRecordRetentionPolicy retention,
    );

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TrackingExampleApp());
}

class TrackingExampleApp extends StatelessWidget {
  const TrackingExampleApp({super.key, this.controllerFactory});

  final ExampleTrackingControllerFactory? controllerFactory;

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00796B),
      brightness: Brightness.light,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Background location tracker',
      theme: ThemeData(
        colorScheme: colors,
        scaffoldBackgroundColor: colors.surfaceContainerLowest,
        appBarTheme: AppBarTheme(
          backgroundColor: colors.surfaceContainerLowest,
          foregroundColor: colors.onSurface,
          elevation: 0,
          scrolledUnderElevation: 1,
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

  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  TrackingController? _tracking;
  TrackingSessionSnapshot? _session;
  TrackRecordRetentionPolicy _retention = TrackRecordRetentionPolicy.keepAll;
  TrackingAccuracy _accuracy = TrackingAccuracy.high;
  List<Track> _tracks = const <Track>[];
  String? _historyCursor;
  bool _historyHasMore = false;
  bool _busy = true;
  String? _message;

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
              TrackingClient.open(
                owner: _owner,
                configuration: TrackingConfiguration(
                  recordRetentionPolicy: _retention,
                ),
              ));
      _tracking = controller;
      _subscriptions
        ..add(
          controller.sessionStream.listen((session) {
            if (mounted) setState(() => _session = session);
          }),
        )
        ..add(
          controller.trackHistoryEvents.listen((_) {
            unawaited(_refreshTracks());
          }),
        );
      _session = controller.currentSession;
      await _refreshTracks();
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
    setState(() {
      _busy = true;
      _message = null;
    });
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
    setState(() {
      _busy = false;
      _message = error.toString();
    });
  }

  Future<void> _refreshTracks({bool append = false}) async {
    final tracking = _tracking;
    if (tracking == null) return;
    final page = await tracking.listTrackPage(
      TrackQuery(limit: 25, cursor: append ? _historyCursor : null),
    );
    if (!mounted) return;
    setState(() {
      _tracks = append
          ? List<Track>.unmodifiable(<Track>[..._tracks, ...page.items])
          : page.items;
      _historyCursor = page.nextCursor;
      _historyHasMore = page.hasMore;
    });
  }

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
          setState(
            () => _message = 'Tap Start again to request Always access.',
          );
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
    await _tracking!.startNewTrack(
      TrackStartRequest(
        owner: _owner,
        routeId: routeId,
        config: TrackingConfig(
          accuracy: _accuracy,
          mockLocationPolicy: MockLocationPolicy.flag,
        ),
      ),
    );
    await _refreshTracks();
  });

  Future<void> _pause() => _run(() async {
    await _tracking!.pauseCurrentTrack(reason: 'example_pause');
    await _refreshTracks();
  });

  Future<void> _resume() => _run(() async {
    if (!await _ensureReady()) return;
    await _tracking!.resumeCurrentTrack();
    await _refreshTracks();
  });

  Future<void> _complete() => _run(() async {
    await _tracking!.completeCurrentTrack(reason: 'example_completed');
    await _refreshTracks();
  });

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
      await _refreshTracks();
    });
  }

  Future<void> _exportTrack(String trackId, TrackExportFormat format) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => ExportNameDialog(
        format: format,
        initialFileName:
            'route_${DateTime.now().toUtc().millisecondsSinceEpoch}',
      ),
    );
    if (name == null) return;
    await _run(() async {
      final result = await _tracking!.exportTrack(
        trackId: trackId,
        format: format,
        fileName: name,
      );
      if (mounted) {
        setState(
          () => _message =
              'Exported ${result.pointCount} points to ${result.path}',
        );
      }
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
      await _refreshTracks();
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
    if (mounted) {
      setState(
        () => _message = doctor.passed
            ? 'Setup doctor: all applicable checks passed.'
            : 'Setup doctor findings: $failures',
      );
    }
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
    if (!mounted) return;
    setState(() {
      _message = result.opened
          ? 'In Android battery settings, allow this app to ignore battery '
                'optimization or select Unrestricted/No restrictions.'
          : result.supported
          ? 'Battery optimization settings could not be opened.'
          : 'Battery optimization settings are not available on this platform.';
    });
  });

  @override
  void dispose() {
    unawaited(_cancelSubscriptions());
    final tracking = _tracking;
    if (tracking != null) unawaited(tracking.dispose().catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tracking = _tracking;
    final actions = _session?.allowedActions;
    final canConfigure = !_busy && _session?.currentTrack == null;
    final hasOwnerConflict = _session?.blockerCode == 'owner_scope_conflict';
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Location tracker'),
            Text(
              'Background route example',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Setup doctor',
            onPressed: _busy || tracking == null ? null : _showDiagnostics,
            icon: const Icon(Icons.health_and_safety_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: <Widget>[
                TrackingStatusCard(session: _session),
                if (_message != null) ...<Widget>[
                  const SizedBox(height: 12),
                  _MessageCard(message: _message!),
                ],
                if (hasOwnerConflict) ...<Widget>[
                  const SizedBox(height: 12),
                  OwnerConflictCard(
                    onResolve: _busy ? null : _resolveOwnerConflict,
                  ),
                ],
                const SizedBox(height: 12),
                TrackingConfigurationControls(
                  retention: _retention,
                  accuracy: _accuracy,
                  enabled: canConfigure,
                  onRetentionChanged: _changeRetention,
                  onAccuracyChanged: _changeAccuracy,
                ),
                const SizedBox(height: 12),
                TrackingActionPanel(
                  canStart: !_busy && actions?.canStartNew == true,
                  canPause: !_busy && actions?.canPause == true,
                  canResume: !_busy && actions?.canResume == true,
                  canComplete: !_busy && actions?.canComplete == true,
                  settingsEnabled: !_busy && tracking != null,
                  showBatterySettings: _accuracy == TrackingAccuracy.precised,
                  onStart: _start,
                  onPause: _pause,
                  onResume: _resume,
                  onComplete: _complete,
                  onAppSettings: () => tracking!.openSettings(
                    TrackingSettingsDestination.application,
                  ),
                  onBatterySettings: _openBatteryOptimizationSettings,
                ),

                const SizedBox(height: 12),
                RecordedTracksSection(
                  tracks: _tracks,
                  hasMore: _historyHasMore,
                  onRefresh: _busy ? null : _refreshTracks,
                  onLoadMore: _busy ? null : () => _refreshTracks(append: true),
                  onViewMap: _busy || tracking == null
                      ? null
                      : (track) async {
                          await Navigator.push<void>(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => TrackMapPage(
                                tracking: tracking,
                                track: track,
                              ),
                            ),
                          );
                        },
                  onExport: _busy ? null : _exportTrack,
                  onDelete: _busy ? null : _deleteTrack,
                ),
                if (_busy) ...<Widget>[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline_rounded, color: colors.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(child: SelectableText(message)),
        ],
      ),
    );
  }
}
