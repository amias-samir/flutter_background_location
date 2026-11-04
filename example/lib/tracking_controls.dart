import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

import 'route_totals.dart';
import 'ui_kit.dart';

/// The current session: its lifecycle, route and live figures.
class TrackingStatusCard extends StatelessWidget {
  const TrackingStatusCard({
    super.key,
    required this.session,
    this.showDiagnostics = true,
  });

  final TrackingSessionSnapshot? session;

  /// Whether the capture diagnostics show: activity confidence, motion
  /// evidence, capture profile, fix state, sequence and mock signal.
  final bool showDiagnostics;

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
    final track = value?.currentTrack;
    final accuracy = value?.lastPoint?.horizontalAccuracy;
    final metrics = <Widget>[
      StatTile(
        value: value?.activity.type.value ?? 'unknown',
        label: 'Activity',
        icon: Icons.directions_walk_outlined,
      ),
      StatTile(
        value: accuracy == null ? '—' : '${accuracy.toStringAsFixed(1)} m',
        label: 'Uncertainty',
        icon: Icons.gps_fixed,
      ),
      StatTile(
        value: track == null ? '—' : kilometres(track.totalDistanceMeters),
        label: 'Distance',
        icon: Icons.straighten_rounded,
      ),
      if (showDiagnostics) ...<Widget>[
        StatTile(
          value: value == null
              ? 'unknown'
              : value.activity.evidenceState == ActivityEvidenceState.fresh
              ? '${value.activity.confidence}%'
              : value.activity.evidenceState.name,
          label: 'Confidence',
          icon: Icons.query_stats,
        ),
        StatTile(
          value: _motionEvidenceLabel(value?.motionEvidence),
          label: 'Motion',
          icon: Icons.sensors_rounded,
        ),
        StatTile(
          value: value?.status.samplingProfile.name ?? 'unknown',
          label: 'Profile',
          icon: Icons.battery_saver_outlined,
        ),
        StatTile(
          value: value?.fixState.name ?? 'idle',
          label: 'Fix',
          icon: Icons.health_and_safety_outlined,
        ),
        StatTile(
          value: '${value?.lastPoint?.sequence ?? '—'}',
          label: 'Sequence',
          icon: Icons.pin_outlined,
        ),
        StatTile(
          value: value?.lastPoint?.mockAssessment.name ?? '—',
          label: 'Mock',
          icon: Icons.verified_user_outlined,
        ),
      ],
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(_lifecycleIcon(lifecycle), size: 20, color: tone),
                const SizedBox(width: 8),
                Flexible(
                  child: StatusPill(
                    label: _displayName(lifecycle?.name ?? 'initializing'),
                    color: tone,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    track == null ? '' : 'since ${clockTime(track.startedAt)}',
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              track?.routeId ?? 'No active route',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: track == null ? colors.onSurfaceVariant : null,
              ),
            ),
            const SizedBox(height: 14),
            StatGrid(
              columns: 3,
              spacing: 16,
              runSpacing: 14,
              children: metrics,
            ),
            if (value?.blockerCode != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: colors.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Blocked: ${value!.blockerCode}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.error,
                          fontWeight: FontWeight.w500,
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

  static String _motionEvidenceLabel(MotionEvidenceSnapshot? evidence) {
    if (evidence == null) return '—';
    final sources = evidence.supportingSources
        .map((source) => source.name)
        .take(2)
        .join('+');
    return sources.isEmpty
        ? evidence.state.name
        : '${evidence.state.name} • $sources';
  }
}

/// How each preference reads on its tile and in its picker.
abstract final class PreferenceLabels {
  static String accuracy(TrackingAccuracy value) => switch (value) {
    TrackingAccuracy.low => 'Low',
    TrackingAccuracy.medium => 'Medium',
    TrackingAccuracy.high => 'High',
    TrackingAccuracy.precised => 'Precised',
  };

  static String accuracyDetail(TrackingAccuracy value) => switch (value) {
    TrackingAccuracy.low => 'Fewer, coarser fixes; the least battery.',
    TrackingAccuracy.medium => 'Balanced detail and battery.',
    TrackingAccuracy.high => 'Detailed routes; the default.',
    TrackingAccuracy.precised =>
      '3-second navigation-grade updates, fixes within 15 m; the most '
          'battery.',
  };

  static String intent(RouteCaptureIntent value) => switch (value) {
    RouteCaptureIntent.adaptive => 'Adaptive',
    RouteCaptureIntent.walking => 'Walking',
    RouteCaptureIntent.cycling => 'Cycling',
    RouteCaptureIntent.vehicle => 'Vehicle',
  };

  /// How [intent] captures a route at [accuracy], from the configuration
  /// the package resolves for the two: its fix rate while moving and still,
  /// the fixes it keeps, and whether it records stops.
  static String intentDetail(
    RouteCaptureIntent intent,
    TrackingAccuracy accuracy,
  ) {
    final config = TrackingConfig(accuracy: accuracy, captureIntent: intent);
    final moving =
        'a fix every ${_every(config.movingInterval)} or '
        '${config.movingDistanceFilterMeters} m'
        '${config.turnCaptureDegrees > 0 ? ' and at each turn' : ''}';
    final keeps =
        'keeps fixes within '
        '${config.maximumAcceptedAccuracyMeters.round()} m';
    final limit = config.maximumAcceptedAccuracyMeters.round();
    final riding = TrackingConfig.defaultMaximumAcceptedAccuracyMeters(
      accuracy,
      RouteCaptureIntent.vehicle,
    ).round();
    final wider = TrackingConfig.defaultMaximumAcceptedAccuracyMeters(
      accuracy,
      RouteCaptureIntent.walking,
    ).round();
    return switch (intent) {
      RouteCaptureIntent.adaptive =>
        'Moving: $moving. Still: slows to every '
            '${_every(config.stationaryInterval)} or '
            '${config.stationaryDistanceFilterMeters} m. Records stops; '
            '$keeps${riding > limit ? ' ($riding m while riding)' : ''}.',
      RouteCaptureIntent.walking || RouteCaptureIntent.cycling =>
        'Always $moving, never slowing when still. '
            '${_capitalized(keeps)}; no stop records. Walking and cycling '
            'capture alike.',
      RouteCaptureIntent.vehicle =>
        'Always $moving, never slowing when still. '
            '${_capitalized(keeps)}'
            '${limit > wider ? ', wider for urban streets' : ''}; no stop '
            'records.',
    };
  }

  /// "5 s", "1 min".
  static String _every(Duration duration) => duration.inSeconds < 60
      ? '${duration.inSeconds} s'
      : '${duration.inMinutes} min';

  static String _capitalized(String text) =>
      '${text[0].toUpperCase()}${text.substring(1)}';

  static String motion(MotionFusionMode value) => switch (value) {
    MotionFusionMode.platformActivityOnly => 'Activity only',
    MotionFusionMode.lowPowerSensorFusion => 'Low-power sensors',
    MotionFusionMode.enhancedSensorFusion => 'Enhanced sensors',
  };

  static String motionDetail(MotionFusionMode value) => switch (value) {
    MotionFusionMode.platformActivityOnly =>
      'The platform\'s activity recognition alone.',
    MotionFusionMode.lowPowerSensorFusion => 'Adds low-power motion sensors.',
    MotionFusionMode.enhancedSensorFusion =>
      'Adds more motion sensors; more battery.',
  };

  static String presentation(MultiDayRoutePresentation value) =>
      switch (value) {
        MultiDayRoutePresentation.separateRecordedParts => 'Separate parts',
        MultiDayRoutePresentation.connectDailyLegs => 'Connect days',
        MultiDayRoutePresentation.continuousPresentation => 'Continuous',
      };

  static String presentationDetail(MultiDayRoutePresentation value) =>
      switch (value) {
        MultiDayRoutePresentation.separateRecordedParts =>
          'Keep recorded parts separate.',
        MultiDayRoutePresentation.connectDailyLegs =>
          'Join the days with labeled straight inferred lines.',
        MultiDayRoutePresentation.continuousPresentation =>
          'Join every part with labeled straight inferred lines.',
      };
}

/// The preferences for the next route, each showing its current value; a
/// tap opens its picker. Locked while a route is active.
class TrackingConfigurationControls extends StatelessWidget {
  const TrackingConfigurationControls({
    super.key,
    required this.retention,
    required this.accuracy,
    required this.captureIntent,
    required this.routePresentation,
    required this.motionFusionMode,
    required this.enabled,
    required this.onRetentionChanged,
    required this.onAccuracyChanged,
    required this.onCaptureIntentChanged,
    required this.onRoutePresentationChanged,
    required this.onMotionFusionModeChanged,
  });

  final TrackRecordRetentionPolicy retention;
  final TrackingAccuracy accuracy;
  final RouteCaptureIntent captureIntent;
  final MultiDayRoutePresentation routePresentation;
  final MotionFusionMode motionFusionMode;
  final bool enabled;
  final ValueChanged<TrackRecordRetentionPolicy> onRetentionChanged;
  final ValueChanged<TrackingAccuracy> onAccuracyChanged;
  final ValueChanged<RouteCaptureIntent> onCaptureIntentChanged;
  final ValueChanged<MultiDayRoutePresentation> onRoutePresentationChanged;
  final ValueChanged<MotionFusionMode> onMotionFusionModeChanged;

  /// Opens a picker for [values] and reports a changed choice.
  VoidCallback? _picker<T>(
    BuildContext context, {
    required String title,
    String? description,
    required List<T> values,
    required T selected,
    required String Function(T) labelOf,
    required String Function(T) detailOf,
    required ValueChanged<T> onChanged,
  }) => enabled
      ? () async {
          final picked = await showPreferencePicker<T>(
            context: context,
            title: title,
            description: description,
            values: values,
            selected: selected,
            labelOf: labelOf,
            detailOf: detailOf,
          );
          if (picked != null && picked != selected) onChanged(picked);
        }
      : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SectionLabel(
          'Tracking preferences',
          trailing: enabled
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Locked while tracking',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        StatGrid(
          columns: 2,
          spacing: 8,
          children: <Widget>[
            PreferenceTile(
              icon: Icons.gps_fixed_rounded,
              label: 'Accuracy',
              value: PreferenceLabels.accuracy(accuracy),
              onTap: _picker(
                context,
                title: 'Accuracy profile',
                description: 'How often and how precisely fixes are requested.',
                values: TrackingAccuracy.values,
                selected: accuracy,
                labelOf: PreferenceLabels.accuracy,
                detailOf: PreferenceLabels.accuracyDetail,
                onChanged: onAccuracyChanged,
              ),
            ),
            PreferenceTile(
              icon: Icons.directions_walk_rounded,
              label: 'Capture intent',
              value: PreferenceLabels.intent(captureIntent),
              onTap: _picker(
                context,
                title: 'Capture intent',
                description:
                    'How each intent captures a route at '
                    '${PreferenceLabels.accuracy(accuracy)} accuracy.',
                values: RouteCaptureIntent.values,
                selected: captureIntent,
                labelOf: PreferenceLabels.intent,
                detailOf: (intent) =>
                    PreferenceLabels.intentDetail(intent, accuracy),
                onChanged: onCaptureIntentChanged,
              ),
            ),
            PreferenceTile(
              icon: Icons.sensors_rounded,
              label: 'Motion evidence',
              value: PreferenceLabels.motion(motionFusionMode),
              onTap: _picker(
                context,
                title: 'Motion evidence',
                description:
                    'Optional sensors improve moving/stationary decisions, '
                    'not coordinates.',
                values: MotionFusionMode.values,
                selected: motionFusionMode,
                labelOf: PreferenceLabels.motion,
                detailOf: PreferenceLabels.motionDetail,
                onChanged: onMotionFusionModeChanged,
              ),
            ),
            PreferenceTile(
              icon: Icons.route_rounded,
              label: 'Multi-day display',
              value: PreferenceLabels.presentation(routePresentation),
              onTap: _picker(
                context,
                title: 'Multi-day route display',
                description:
                    'Connected modes add labeled straight inferred lines.',
                values: MultiDayRoutePresentation.values,
                selected: routePresentation,
                labelOf: PreferenceLabels.presentation,
                detailOf: PreferenceLabels.presentationDetail,
                onChanged: onRoutePresentationChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 12),
              child: Text('History', style: theme.textTheme.labelLarge),
            ),
            Expanded(
              child: SegmentedButton<TrackRecordRetentionPolicy>(
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                showSelectedIcon: false,
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
            ),
          ],
        ),
        if (accuracy == TrackingAccuracy.precised)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: colors.tertiaryContainer.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.battery_alert_outlined,
                  size: 18,
                  color: colors.onTertiaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Precised: 3 s updates within 15 m, more battery.',
                    maxLines: 2,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The route's lifecycle actions, only those allowed now: Start while idle;
/// Pause or Resume, then Complete and, for a Trip, End day while a route is
/// open. A disabled Start shows while nothing is allowed.
class TrackingActionPanel extends StatelessWidget {
  const TrackingActionPanel({
    super.key,
    required this.canStart,
    required this.canPause,
    required this.canResume,
    required this.canComplete,
    this.canEndDay = false,
    this.tripMode = false,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onComplete,
    this.onEndDay,
  });

  final bool canStart;
  final bool canPause;
  final bool canResume;
  final bool canComplete;
  final bool canEndDay;
  final bool tripMode;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onComplete;
  final VoidCallback? onEndDay;

  @override
  Widget build(BuildContext context) {
    final actions = <_Action>[
      if (canPause) _Action(_Kind.tonal, Icons.pause_rounded, 'Pause', onPause),
      if (canResume)
        _Action(_Kind.filled, Icons.play_arrow_rounded, 'Resume', onResume),
      if (tripMode && canEndDay)
        _Action(_Kind.tonal, Icons.bedtime_outlined, 'End day', onEndDay),
      if (canComplete)
        _Action(
          _Kind.outlined,
          Icons.flag_outlined,
          tripMode ? 'Complete Trip' : 'Complete',
          onComplete,
        ),
    ];
    if (actions.isEmpty) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: canStart ? onStart : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Start'),
        ),
      );
    }
    // Three actions stack each icon over its label to keep the labels whole.
    final stacked = actions.length > 2;
    return Row(
      children: <Widget>[
        for (final (index, action) in actions.indexed) ...<Widget>[
          if (index > 0) const SizedBox(width: 8),
          Expanded(child: action.build(stacked: stacked)),
        ],
      ],
    );
  }
}

enum _Kind { filled, tonal, outlined }

/// One lifecycle button of [TrackingActionPanel].
final class _Action {
  const _Action(this.kind, this.icon, this.label, this.onPressed);

  final _Kind kind;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  Widget build({required bool stacked}) {
    if (!stacked) {
      final iconWidget = Icon(icon);
      final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
      return switch (kind) {
        _Kind.filled => FilledButton.icon(
          onPressed: onPressed,
          icon: iconWidget,
          label: text,
        ),
        _Kind.tonal => FilledButton.tonalIcon(
          onPressed: onPressed,
          icon: iconWidget,
          label: text,
        ),
        _Kind.outlined => OutlinedButton.icon(
          onPressed: onPressed,
          icon: iconWidget,
          label: text,
        ),
      };
    }
    const style = ButtonStyle(
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      ),
      minimumSize: WidgetStatePropertyAll(Size(0, 60)),
    );
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 20),
        const SizedBox(height: 2),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
    return switch (kind) {
      _Kind.filled => FilledButton(
        onPressed: onPressed,
        style: style,
        child: child,
      ),
      _Kind.tonal => FilledButton.tonal(
        onPressed: onPressed,
        style: style,
        child: child,
      ),
      _Kind.outlined => OutlinedButton(
        onPressed: onPressed,
        style: style,
        child: child,
      ),
    };
  }
}

/// A route of another owner still collects locations on this device.
class OwnerConflictCard extends StatelessWidget {
  const OwnerConflictCard({super.key, required this.onResolve});

  final VoidCallback? onResolve;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.manage_accounts_outlined,
              color: colors.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Another owner is tracking on this device',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onErrorContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            TextButton(
              onPressed: onResolve,
              child: const Text('Pause other session'),
            ),
          ],
        ),
      ),
    );
  }
}
