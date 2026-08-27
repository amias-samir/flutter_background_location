import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

class TrackingStatusCard extends StatelessWidget {
  const TrackingStatusCard({super.key, required this.session});

  final TrackingSessionSnapshot? session;

  @override
  Widget build(BuildContext context) {
    final value = session;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final lifecycle = value?.status.lifecycle;
    final tone = switch (lifecycle) {
      TrackerLifecycle.tracking => colors.primary,
      TrackerLifecycle.paused => colors.tertiary,
      TrackerLifecycle.interrupted || TrackerLifecycle.failed => colors.error,
      _ => colors.secondary,
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(_lifecycleIcon(lifecycle), color: tone),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'CURRENT SESSION',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _displayName(lifecycle?.name ?? 'initializing'),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: tone,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              value?.currentTrack?.routeId ?? 'No route is selected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _StatusMetric(
                  icon: Icons.directions_walk_outlined,
                  label: 'Activity',
                  value: value?.activity.type.value ?? 'unknown',
                ),
                _StatusMetric(
                  icon: Icons.query_stats,
                  label: 'Confidence',
                  value: value == null
                      ? 'unknown'
                      : '${value.activity.confidence}%',
                ),
                _StatusMetric(
                  icon: Icons.gps_fixed,
                  label: 'Fix',
                  value: value?.fixState.name ?? 'idle',
                ),
                _StatusMetric(
                  icon: Icons.pin_outlined,
                  label: 'Sequence',
                  value: '${value?.lastPoint?.sequence ?? 'none'}',
                ),
                _StatusMetric(
                  icon: Icons.verified_user_outlined,
                  label: 'Mock signal',
                  value: value?.lastPoint?.mockAssessment.name ?? 'unavailable',
                ),
              ],
            ),
            if (value?.blockerCode != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.warning_amber_rounded, color: colors.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Blocked: ${value!.blockerCode}',
                        style: TextStyle(
                          color: colors.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static IconData _lifecycleIcon(TrackerLifecycle? lifecycle) =>
      switch (lifecycle) {
        TrackerLifecycle.tracking => Icons.route,
        TrackerLifecycle.paused => Icons.pause_rounded,
        TrackerLifecycle.interrupted => Icons.portable_wifi_off_rounded,
        TrackerLifecycle.failed => Icons.error_outline,
        TrackerLifecycle.starting => Icons.hourglass_top_rounded,
        TrackerLifecycle.stopping => Icons.hourglass_bottom_rounded,
        _ => Icons.location_searching,
      };

  static String _displayName(String value) =>
      value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';
}

class _StatusMetric extends StatelessWidget {
  const _StatusMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: colors.primary),
          const SizedBox(width: 6),
          Text('$label: ', style: Theme.of(context).textTheme.labelMedium),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
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
  Widget build(BuildContext context) => Card(
    elevation: 0,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.tune_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Text(
                'Tracking preferences',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Choose how routes are stored and how frequently fixes are requested.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          Text(
            'History retention',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          SegmentedButton<TrackRecordRetentionPolicy>(
            segments: const <ButtonSegment<TrackRecordRetentionPolicy>>[
              ButtonSegment(
                value: TrackRecordRetentionPolicy.keepAll,
                icon: Icon(Icons.all_inbox_outlined),
                label: Text('Keep all'),
              ),
              ButtonSegment(
                value: TrackRecordRetentionPolicy.keepLatestOnly,
                icon: Icon(Icons.filter_1_outlined),
                label: Text('Latest only'),
              ),
            ],
            selected: <TrackRecordRetentionPolicy>{retention},
            onSelectionChanged: enabled
                ? (value) => onRetentionChanged(value.single)
                : null,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<TrackingAccuracy>(
            initialValue: accuracy,
            decoration: const InputDecoration(
              labelText: 'Accuracy profile',
              prefixIcon: Icon(Icons.gps_fixed_rounded),
              border: OutlineInputBorder(),
            ),
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
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.tertiaryContainer.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.battery_alert_outlined,
                    color: Theme.of(context).colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Precised requests 5-second navigation-grade updates, accepts fixes within 15 m, and can use significantly more battery.',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

class TrackingActionPanel extends StatelessWidget {
  const TrackingActionPanel({
    super.key,
    required this.canStart,
    required this.canPause,
    required this.canResume,
    required this.canComplete,
    required this.settingsEnabled,
    required this.showBatterySettings,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onComplete,
    required this.onAppSettings,
    required this.onBatterySettings,
  });

  final bool canStart;
  final bool canPause;
  final bool canResume;
  final bool canComplete;
  final bool settingsEnabled;
  final bool showBatterySettings;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onComplete;
  final VoidCallback onAppSettings;
  final VoidCallback onBatterySettings;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.route_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Text(
                'Route controls',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Available actions follow the current route lifecycle.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: canStart ? onStart : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Start'),
              ),
              FilledButton.tonalIcon(
                onPressed: canPause ? onPause : null,
                icon: const Icon(Icons.pause_rounded),
                label: const Text('Pause'),
              ),
              FilledButton.tonalIcon(
                onPressed: canResume ? onResume : null,
                icon: const Icon(Icons.play_circle_outline_rounded),
                label: const Text('Resume'),
              ),
              OutlinedButton.icon(
                onPressed: canComplete ? onComplete : null,
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Complete'),
              ),
            ],
          ),
          const Divider(height: 28),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: settingsEnabled ? onAppSettings : null,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('App settings'),
              ),
              if (showBatterySettings)
                OutlinedButton.icon(
                  onPressed: settingsEnabled ? onBatterySettings : null,
                  icon: const Icon(Icons.battery_saver_outlined),
                  label: const Text('Battery settings'),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class OwnerConflictCard extends StatelessWidget {
  const OwnerConflictCard({super.key, required this.onResolve});

  final VoidCallback? onResolve;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.manage_accounts_outlined,
              color: colors.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Another owner is tracking on this device',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colors.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Pause that local session before starting a route for the current owner.',
                    style: TextStyle(color: colors.onErrorContainer),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: onResolve,
                    icon: const Icon(Icons.pause_circle_outline),
                    label: const Text('Pause other session'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
