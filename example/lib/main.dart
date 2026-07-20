import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_location/flutter_background_location.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TrackingExampleApp());
}

class TrackingExampleApp extends StatelessWidget {
  const TrackingExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Background location example',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      useMaterial3: true,
    ),
    home: const TrackingExamplePage(),
  );
}

class TrackingExamplePage extends StatefulWidget {
  const TrackingExamplePage({super.key});

  @override
  State<TrackingExamplePage> createState() => _TrackingExamplePageState();
}

class _TrackingExamplePageState extends State<TrackingExamplePage> {
  final FieldTrackingClient _tracking = FieldTrackingClient();
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  TrackerStatus _status = const TrackerStatus(lifecycle: TrackerLifecycle.idle);
  ActivitySnapshot _activity = const ActivitySnapshot.unknown();
  TrackPoint? _lastPoint;
  String? _trackId;
  String? _message;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _tracking.initialize();
      _subscriptions
        ..add(
          _tracking.statusStream.listen((value) {
            if (mounted) setState(() => _status = value);
          }),
        )
        ..add(
          _tracking.activityStream.listen((value) {
            if (mounted) setState(() => _activity = value);
          }),
        )
        ..add(
          _tracking.pointStream.listen((value) {
            if (mounted) setState(() => _lastPoint = value);
          }),
        )
        ..add(
          _tracking.watchCurrentTrack().listen((value) {
            if (mounted && value != null) {
              setState(() => _trackId = value.id);
            }
          }),
        );
      setState(() {
        _status = _tracking.currentStatus;
        _busy = false;
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on TrackingPermissionException catch (error) {
      final guidance = error.state.canRequestBackground
          ? 'Explain why background tracking is needed, then try Start again.'
          : error.state.requiresSettings
          ? 'Open app settings and enable “Always/Allow all the time”.'
          : 'Grant the requested permission and try again.';
      _showError('$error $guidance');
      return;
    } catch (error) {
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

  Future<void> _start() => _run(() async {
    _trackId = await _tracking.startTrack(
      userId: 'example-user',
      organizationId: 'example-organization',
      config: const TrackingConfig(mockLocationPolicy: MockLocationPolicy.flag),
    );
  });

  Future<void> _pause() => _run(
    () => _tracking.pauseTrack(trackId: _trackId, reason: 'example_pause'),
  );

  Future<void> _resume() => _run(() async {
    final trackId = _trackId;
    if (trackId == null) return;
    await _tracking.resumeTrack(trackId);
  });

  Future<void> _complete() => _run(
    () =>
        _tracking.completeTrack(trackId: _trackId, reason: 'example_completed'),
  );

  Future<void> _export(TrackExportFormat format) => _run(() async {
    final trackId = _trackId;
    if (trackId == null) return;
    final result = await _tracking.exportTrack(
      trackId: trackId,
      format: format,
    );
    if (mounted) {
      setState(
        () => _message =
            'Exported ${result.pointCount} points to '
            '${result.path}',
      );
    }
  });

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canStart =
        _status.lifecycle == TrackerLifecycle.idle || _trackId == null;
    final canPause = _status.lifecycle == TrackerLifecycle.tracking;
    final canResume =
        _status.lifecycle == TrackerLifecycle.paused ||
        _status.lifecycle == TrackerLifecycle.interrupted;
    final canComplete =
        _trackId != null &&
        _status.lifecycle != TrackerLifecycle.idle &&
        _status.lifecycle != TrackerLifecycle.stopping;

    return Scaffold(
      appBar: AppBar(title: const Text('Background location tracker')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _StatusCard(
            status: _status,
            activity: _activity,
            point: _lastPoint,
            trackId: _trackId,
          ),
          const SizedBox(height: 12),
          const Text(
            'Location exports contain sensitive route data. Share them only '
            'with a destination you trust.',
          ),
          if (_message != null) ...<Widget>[
            const SizedBox(height: 12),
            SelectableText(_message!),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                onPressed: !_busy && canStart ? _start : null,
                child: const Text('Start'),
              ),
              FilledButton.tonal(
                onPressed: !_busy && canPause ? _pause : null,
                child: const Text('Pause'),
              ),
              FilledButton.tonal(
                onPressed: !_busy && canResume ? _resume : null,
                child: const Text('Resume'),
              ),
              OutlinedButton(
                onPressed: !_busy && canComplete ? _complete : null,
                child: const Text('Complete'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _tracking.openAppSettings,
                child: const Text('Open app settings'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: TrackExportFormat.values
                .map(
                  (format) => TextButton(
                    onPressed:
                        !_busy && _status.lifecycle == TrackerLifecycle.idle
                        ? () => _export(format)
                        : null,
                    child: Text('Export ${format.name}'),
                  ),
                )
                .toList(growable: false),
          ),
          if (_busy) ...<Widget>[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.activity,
    required this.point,
    required this.trackId,
  });

  final TrackerStatus status;
  final ActivitySnapshot activity;
  final TrackPoint? point;
  final String? trackId;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Lifecycle: ${status.lifecycle.name}'),
          Text('Track: ${trackId ?? 'none'}'),
          Text('Activity: ${activity.type.value} (${activity.confidence}%)'),
          Text('Motion: ${status.motionState.name}'),
          Text('Sampling: ${status.samplingProfile.name}'),
          Text('Last sequence: ${point?.sequence ?? 'none'}'),
          Text('Mock signal: ${point?.mockAssessment.name ?? 'unavailable'}'),
        ],
      ),
    ),
  );
}
