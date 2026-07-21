import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_background_location/flutter_background_location.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;

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
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  late FieldTrackingClient _tracking;
  TrackRecordRetentionPolicy _retentionPolicy =
      TrackRecordRetentionPolicy.keepLatestOnly;
  TrackerStatus _status = const TrackerStatus(lifecycle: TrackerLifecycle.idle);
  ActivitySnapshot _activity = const ActivitySnapshot.unknown();
  TrackPoint? _lastPoint;
  String? _trackId;
  String? _completedTrackId;
  String? _message;
  List<Track> _tracks = const <Track>[];
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _tracking = _createTrackingClient();
    unawaited(_initialize());
  }

  FieldTrackingClient _createTrackingClient() => FieldTrackingClient(
    configuration: FieldTrackingConfiguration(
      recordRetentionPolicy: _retentionPolicy,
    ),
  );

  Future<void> _initialize() async {
    try {
      await _tracking.initialize();

      _listenToTrackingClient();
      setState(() {
        _status = _tracking.currentStatus;
        _busy = false;
      });
      await _refreshTracks();
    } catch (error) {
      _showError(error);
    }
  }

  void _listenToTrackingClient() {
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
  }

  Future<void> _cancelTrackingSubscriptions() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> _disposeTrackingClient() async {
    try {
      await _tracking.dispose();
    } catch (_) {
      // The client intentionally refuses disposal while native tracking is
      // active. The app lifecycle will keep the foreground service visible.
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

  Future<void> _refreshTracks() async {
    final tracks = await _tracking.listTracks();
    if (!mounted) return;
    setState(() => _tracks = tracks);
  }

  Future<void> _changeRetentionPolicy(TrackRecordRetentionPolicy value) async {
    if (value == _retentionPolicy || _busy || _trackId != null) return;
    setState(() {
      _busy = true;
      _message = null;
      _retentionPolicy = value;
    });
    try {
      await _cancelTrackingSubscriptions();
      await _tracking.dispose();
      _tracking = _createTrackingClient();
      await _tracking.initialize();
      _listenToTrackingClient();
      final tracks = await _tracking.listTracks();
      if (!mounted) return;
      setState(() {
        _status = _tracking.currentStatus;
        _activity = _tracking.currentActivity;
        _tracks = tracks;
        _busy = false;
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _start() => _run(() async {
    if (_trackId != null &&
        (_status.lifecycle == TrackerLifecycle.paused ||
            _status.lifecycle == TrackerLifecycle.interrupted ||
            _status.lifecycle == TrackerLifecycle.failed)) {
      await _tracking.resumeTrack(_trackId!);
      await _refreshTracks();
      return;
    }
    _trackId = await _tracking.startTrack(
      userId: 'example-user',
      organizationId: 'example-organization',
      config: const TrackingConfig(mockLocationPolicy: MockLocationPolicy.flag,
        movingDistanceFilterMeters: 5,
        movingInterval: Duration(seconds: 5),
        maximumAcceptedAccuracyMeters: 40
      ),
    );
    _completedTrackId = null;
    await _refreshTracks();
  });

  Future<void> _pause() => _run(() async {
    await _tracking.pauseTrack(trackId: _trackId, reason: 'example_pause');
    await _refreshTracks();
  });

  Future<void> _resume() => _run(() async {
    final trackId = _trackId;
    if (trackId == null) return;
    await _tracking.resumeTrack(trackId);
    await _refreshTracks();
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
    await _refreshTracks();
  });

  Future<void> _viewTrackOnMap(Track track) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TrackMapPage(tracking: _tracking, track: track),
      ),
    );
    await _refreshTracks();
  }

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
    unawaited(_cancelTrackingSubscriptions());
    unawaited(_disposeTrackingClient());
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
    final canConfigureRetention =
        !_busy &&
        _status.lifecycle == TrackerLifecycle.idle &&
        _trackId == null;

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
          _RetentionPolicyControl(
            value: _retentionPolicy,
            enabled: canConfigureRetention,
            onChanged: _changeRetentionPolicy,
          ),
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
          const SizedBox(height: 16),
          _RecordedTracksSection(
            tracks: _tracks,
            onRefresh: _busy ? null : _refreshTracks,
            onViewMap: _busy ? null : _viewTrackOnMap,
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

class _RetentionPolicyControl extends StatelessWidget {
  const _RetentionPolicyControl({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final TrackRecordRetentionPolicy value;
  final bool enabled;
  final ValueChanged<TrackRecordRetentionPolicy> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('Track retention', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      SegmentedButton<TrackRecordRetentionPolicy>(
        segments: const <ButtonSegment<TrackRecordRetentionPolicy>>[
          ButtonSegment<TrackRecordRetentionPolicy>(
            value: TrackRecordRetentionPolicy.keepLatestOnly,
            icon: Icon(Icons.filter_1),
            label: Text('Latest only'),
          ),
          ButtonSegment<TrackRecordRetentionPolicy>(
            value: TrackRecordRetentionPolicy.keepAll,
            icon: Icon(Icons.history),
            label: Text('Keep all'),
          ),
        ],
        selected: <TrackRecordRetentionPolicy>{value},
        onSelectionChanged: enabled
            ? (selection) => onChanged(selection.single)
            : null,
      ),
      const SizedBox(height: 6),
      Text(
        value == TrackRecordRetentionPolicy.keepLatestOnly
            ? 'Older tracks are deleted when a new track starts.'
            : 'Every completed track remains in the local database.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}

class _RecordedTracksSection extends StatelessWidget {
  const _RecordedTracksSection({
    required this.tracks,
    required this.onRefresh,
    required this.onViewMap,
  });

  final List<Track> tracks;
  final Future<void> Function()? onRefresh;
  final Future<void> Function(Track track)? onViewMap;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Row(
        children: <Widget>[
          Text(
            'Recorded tracks',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Refresh tracks',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      if (tracks.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'No recorded tracks yet. Complete a trip to export or map it.',
          ),
        )
      else
        ...tracks.map(
          (track) => Card(
            child: ListTile(
              title: Text(_trackTitle(track)),
              subtitle: Text(_trackSubtitle(track)),
              trailing: IconButton(
                tooltip: 'View route on map',
                onPressed: onViewMap == null ? null : () => onViewMap!(track),
                icon: const Icon(Icons.map_outlined),
              ),
            ),
          ),
        ),
    ],
  );

  static String _trackTitle(Track track) {
    final started = _formatDateTime(track.startedAt);
    return '${track.status.name} • $started';
  }

  static String _trackSubtitle(Track track) {
    final distanceKm = track.totalDistanceMeters / 1000;
    final ended = track.endedAt == null
        ? 'not completed'
        : 'ended ${_formatDateTime(track.endedAt!)}';
    return '${track.acceptedPointCount} points • '
        '${distanceKm.toStringAsFixed(2)} km • '
        '${track.segmentCount} segment(s) • $ended';
  }

  static String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    final date =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    final time =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }
}

class TrackMapPage extends StatelessWidget {
  const TrackMapPage({super.key, required this.tracking, required this.track});

  final FieldTrackingClient tracking;
  final Track track;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Track route')),
    body: FutureBuilder<TrackBundle>(
      future: tracking.loadTrackBundle(track.id),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text(snapshot.error.toString()));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final route = _RouteGeometry.fromBundle(snapshot.requireData);
        if (route.points.isEmpty) {
          return const Center(
            child: Text('This track does not have route coordinates yet.'),
          );
        }
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '${track.status.name} route • '
                '${route.pointCount} accepted points • '
                '${route.segments.length} drawable segment(s)',
              ),
            ),
            Expanded(child: _TrackRouteMap(route: route)),
          ],
        );
      },
    ),
  );
}

class _TrackRouteMap extends StatefulWidget {
  const _TrackRouteMap({required this.route});

  final _RouteGeometry route;

  @override
  State<_TrackRouteMap> createState() => _TrackRouteMapState();
}

class _TrackRouteMapState extends State<_TrackRouteMap> {
  maplibre.MapLibreMapController? _controller;
  bool _styleLoaded = false;
  bool _routeDrawn = false;

  @override
  Widget build(BuildContext context) => maplibre.MapLibreMap(
    styleString: maplibre.MapLibreStyles.openfreemapLiberty,
    initialCameraPosition: maplibre.CameraPosition(
      target: widget.route.center,
      zoom: widget.route.points.length == 1 ? 15 : 13,
    ),
    onMapCreated: (controller) {
      _controller = controller;
      unawaited(_drawRoute());
    },
    onStyleLoadedCallback: () {
      _styleLoaded = true;
      unawaited(_drawRoute());
    },
  );

  Future<void> _drawRoute() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded || _routeDrawn) return;
    _routeDrawn = true;
    for (final segment in widget.route.segments) {
      await controller.addLine(
        maplibre.LineOptions(
          geometry: segment,
          lineColor: '#00796B',
          lineWidth: 5,
          lineOpacity: 0.9,
        ),
      );
    }
    if (widget.route.segments.isEmpty && widget.route.points.isNotEmpty) {
      await controller.addCircle(
        maplibre.CircleOptions(
          geometry: widget.route.points.first,
          circleColor: '#00796B',
          circleRadius: 7,
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2,
        ),
      );
    }
    if (widget.route.points.length == 1) {
      await controller.animateCamera(
        maplibre.CameraUpdate.newLatLng(widget.route.center),
      );
      return;
    }
    await controller.animateCamera(
      maplibre.CameraUpdate.newLatLngBounds(
        widget.route.bounds,
        left: 48,
        top: 48,
        right: 48,
        bottom: 48,
      ),
    );
  }
}

class _RouteGeometry {
  const _RouteGeometry({
    required this.segments,
    required this.points,
    required this.bounds,
    required this.center,
    required this.pointCount,
  });

  final List<List<maplibre.LatLng>> segments;
  final List<maplibre.LatLng> points;
  final maplibre.LatLngBounds bounds;
  final maplibre.LatLng center;
  final int pointCount;

  factory _RouteGeometry.fromBundle(TrackBundle bundle) {
    final allPoints = <maplibre.LatLng>[];
    final drawableSegments = <List<maplibre.LatLng>>[];
    var pointCount = 0;
    for (final segment in bundle.segments) {
      final coordinates = segment.points
          .where((point) => point.accepted && _isValidCoordinate(point))
          .map((point) => maplibre.LatLng(point.latitude, point.longitude))
          .toList(growable: false);
      pointCount += coordinates.length;
      allPoints.addAll(coordinates);
      if (coordinates.length >= 2) {
        drawableSegments.add(coordinates);
      }
    }
    final bounds = _boundsFor(allPoints);
    return _RouteGeometry(
      segments: drawableSegments,
      points: allPoints,
      bounds: bounds,
      center: maplibre.LatLng(
        (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
        (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
      ),
      pointCount: pointCount,
    );
  }

  static bool _isValidCoordinate(TrackPoint point) =>
      point.latitude.isFinite &&
      point.longitude.isFinite &&
      point.latitude >= -90 &&
      point.latitude <= 90 &&
      point.longitude >= -180 &&
      point.longitude <= 180;

  static maplibre.LatLngBounds _boundsFor(List<maplibre.LatLng> points) {
    if (points.isEmpty) {
      const fallback = maplibre.LatLng(0, 0);
      return maplibre.LatLngBounds(southwest: fallback, northeast: fallback);
    }
    var minLatitude = points.first.latitude;
    var maxLatitude = points.first.latitude;
    var minLongitude = points.first.longitude;
    var maxLongitude = points.first.longitude;
    for (final point in points.skip(1)) {
      minLatitude = math.min(minLatitude, point.latitude);
      maxLatitude = math.max(maxLatitude, point.latitude);
      minLongitude = math.min(minLongitude, point.longitude);
      maxLongitude = math.max(maxLongitude, point.longitude);
    }
    if (minLatitude == maxLatitude) {
      minLatitude -= 0.0005;
      maxLatitude += 0.0005;
    }
    if (minLongitude == maxLongitude) {
      minLongitude -= 0.0005;
      maxLongitude += 0.0005;
    }
    return maplibre.LatLngBounds(
      southwest: maplibre.LatLng(minLatitude, minLongitude),
      northeast: maplibre.LatLng(maxLatitude, maxLongitude),
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
          Text('Is Mocked: ${point?.isMocked ?? 'unavailable'}'),
        ],
      ),
    ),
  );
}
