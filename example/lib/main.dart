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
  String? _completedTrackId;
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
            if (mounted) {
              setState(() => _trackId = value?.id);
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
    if (_trackId != null &&
        (_status.lifecycle == TrackerLifecycle.paused ||
            _status.lifecycle == TrackerLifecycle.interrupted ||
            _status.lifecycle == TrackerLifecycle.failed)) {
      await _tracking.resumeTrack(_trackId!);
      return;
    }
    _trackId = await _tracking.startTrack(
      userId: 'example-user',
      organizationId: 'example-organization',
      config: const TrackingConfig(mockLocationPolicy: MockLocationPolicy.flag),
    );
    _completedTrackId = null;
  });

  Future<void> _pause() => _run(
    () => _tracking.pauseTrack(trackId: _trackId, reason: 'example_pause'),
  );

  Future<void> _resume() => _run(() async {
    final trackId = _trackId;
    if (trackId == null) return;
    await _tracking.resumeTrack(trackId);
  });

  Future<void> _complete() => _run(() async {
    final trackId = _trackId;
    if (trackId == null) return;
    await _tracking.completeTrack(
      trackId: trackId,
      reason: 'example_completed',
    );
    if (mounted) {
      setState(() {
        _completedTrackId = trackId;
        _trackId = null;
        _status = const TrackerStatus(lifecycle: TrackerLifecycle.idle);
      });
    }
  });

  Future<void> _export(TrackExportFormat format) async {
    final trackId = _trackId ?? _completedTrackId;
    if (trackId == null) return;
    final fileName = await _askExportFileName(format);
    if (fileName == null) return;
    await _run(() async {
      final result = await _tracking.exportTrack(
        trackId: trackId,
        format: format,
        fileName: fileName,
      );
      if (mounted) {
        setState(
          () => _message =
              'Exported ${result.pointCount} points to '
              '${result.path}',
        );
      }
    });
  }

  Future<String?> _askExportFileName(TrackExportFormat format) async {
    final trackId = _trackId;
    final date = DateTime.now().toUtc().toIso8601String().split('T').first;
    final initialFileName = 'track_${date}_${trackId ?? 'export'}';
    return showDialog<String>(
      context: context,
      builder: (context) =>
          _ExportNameDialog(format: format, initialFileName: initialFileName),
    );
  }

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
        _status.lifecycle == TrackerLifecycle.idle && _trackId == null;
    final canPause = _status.lifecycle == TrackerLifecycle.tracking;
    final canResume =
        _trackId != null &&
        (_status.lifecycle == TrackerLifecycle.paused ||
            _status.lifecycle == TrackerLifecycle.interrupted ||
            _status.lifecycle == TrackerLifecycle.failed);
    final canComplete =
        _trackId != null &&
        _status.lifecycle != TrackerLifecycle.idle &&
        _status.lifecycle != TrackerLifecycle.stopping;
    final canExport =
        _status.lifecycle == TrackerLifecycle.idle && _completedTrackId != null;

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
                    onPressed: !_busy && canExport
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

class _ExportNameDialog extends StatefulWidget {
  const _ExportNameDialog({
    required this.format,
    required this.initialFileName,
  });

  final TrackExportFormat format;
  final String initialFileName;

  @override
  State<_ExportNameDialog> createState() => _ExportNameDialogState();
}

class _ExportNameDialogState extends State<_ExportNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialFileName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final trimmed = _controller.text.trim();
    Navigator.of(context).pop(trimmed.isEmpty ? null : trimmed);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Export ${widget.format.name}'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(
        labelText: 'File name',
        helperText: 'The correct extension is added automatically.',
      ),
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Export')),
    ],
  );
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
