import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

class TrackingStatusCard extends StatelessWidget {
  const TrackingStatusCard({super.key, required this.session});

  final TrackingSessionSnapshot? session;

  @override
  Widget build(BuildContext context) {
    final value = session;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Lifecycle: ${value?.status.lifecycle.name ?? 'initializing'}',
            ),
            Text('Route: ${value?.currentTrack?.routeId ?? 'none'}'),
            Text('Activity: ${value?.activity.type.value ?? 'unknown'}'),
            Text(
              'Activity Confidence: ${value?.activity.confidence ?? 'unknown'}',
            ),
            Text('Fix state: ${value?.fixState.name ?? 'idle'}'),
            Text('Last sequence: ${value?.lastPoint?.sequence ?? 'none'}'),
            Text(
              'Mock signal: ${value?.lastPoint?.mockAssessment.name ?? 'unavailable'}',
            ),
            if (value?.blockerCode != null)
              Text(
                'Blocked: ${value!.blockerCode}',
                style: const TextStyle(color: Colors.red),
              ),
          ],
        ),
      ),
    );
  }
}

class TrackingConfigurationControls extends StatelessWidget {
  const TrackingConfigurationControls({
    super.key,
    required this.retention,
    required this.accuracy,
    required this.enabled,
    required this.onRetentionChanged,
    required this.onAccuracyChanged,
  });

  final TrackRecordRetentionPolicy retention;
  final TrackingAccuracy accuracy;
  final bool enabled;
  final ValueChanged<TrackRecordRetentionPolicy> onRetentionChanged;
  final ValueChanged<TrackingAccuracy> onAccuracyChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('History retention', style: Theme.of(context).textTheme.titleSmall),
      SegmentedButton<TrackRecordRetentionPolicy>(
        segments: const <ButtonSegment<TrackRecordRetentionPolicy>>[
          ButtonSegment(
            value: TrackRecordRetentionPolicy.keepAll,
            label: Text('Keep all'),
          ),
          ButtonSegment(
            value: TrackRecordRetentionPolicy.keepLatestOnly,
            label: Text('Latest only'),
          ),
        ],
        selected: <TrackRecordRetentionPolicy>{retention},
        onSelectionChanged: enabled
            ? (value) => onRetentionChanged(value.single)
            : null,
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<TrackingAccuracy>(
        initialValue: accuracy,
        decoration: const InputDecoration(labelText: 'Accuracy profile'),
        items: TrackingAccuracy.values
            .map(
              (value) =>
                  DropdownMenuItem(value: value, child: Text(value.name)),
            )
            .toList(growable: false),
        onChanged: enabled
            ? (value) {
                if (value != null) onAccuracyChanged(value);
              }
            : null,
      ),
      if (accuracy == TrackingAccuracy.precised)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Precised requests frequent, navigation-grade fixes and can use significantly more battery.',
            style: TextStyle(color: Colors.deepOrange),
          ),
        ),
    ],
  );
}
